/**
 * @description Apex controller for the collectionEntry LWC component.
 *              Creates ONE Collection__c record (matching the physical
 *              payment — e.g., one cheque) plus multiple Collection_Allocation__c
 *              child records when the payment is split across invoices.
 *              Any unallocated portion is flagged as On Account credit.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public with sharing class CollectionEntryController {

    @AuraEnabled
    public static List<Invoice__c> getOutstandingInvoices(Id accountId) {
        // Non-cacheable: balances change after every collection — must refetch fresh
        return CollectionController.getOutstandingInvoices(accountId);
    }

    @AuraEnabled
    public static Collection__c createCollection(String collectionJson) {
        Savepoint sp = Database.setSavepoint();
        try {
            Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(collectionJson);

            Id accountId = (Id) data.get('accountId');
            Decimal totalAmount = data.get('amount') != null
                ? Decimal.valueOf(String.valueOf(data.get('amount'))) : null;

            if (totalAmount == null || totalAmount <= 0) {
                throw new AuraHandledException('Collection amount must be greater than zero.');
            }

            List<Object> rawAllocations = data.get('allocations') != null
                ? (List<Object>) data.get('allocations') : new List<Object>();

            // Filter to active allocations (non-zero amount, valid invoice)
            List<Map<String, Object>> activeAllocations = new List<Map<String, Object>>();
            Decimal totalAllocated = 0;
            for (Object a : rawAllocations) {
                Map<String, Object> alloc = (Map<String, Object>) a;
                Decimal amt = alloc.get('allocatedAmount') != null
                    ? Decimal.valueOf(String.valueOf(alloc.get('allocatedAmount'))) : 0;
                if (amt > 0 && alloc.get('invoiceId') != null) {
                    activeAllocations.add(alloc);
                    totalAllocated += amt;
                }
            }

            // Validate totals
            if (totalAllocated > totalAmount) {
                throw new AuraHandledException(
                    'Total allocated (' + totalAllocated.setScale(2) +
                    ') exceeds collection amount (' + totalAmount.setScale(2) + ').'
                );
            }

            // Validate each allocation against its invoice balance
            if (!activeAllocations.isEmpty()) {
                Set<Id> invoiceIds = new Set<Id>();
                for (Map<String, Object> alloc : activeAllocations) {
                    invoiceIds.add((Id) alloc.get('invoiceId'));
                }
                Map<Id, Invoice__c> invMap = new Map<Id, Invoice__c>([
                    SELECT Id, Name, Balance_Due__c, Status__c
                    FROM Invoice__c WHERE Id IN :invoiceIds
                ]);
                for (Map<String, Object> alloc : activeAllocations) {
                    Id invId = (Id) alloc.get('invoiceId');
                    Decimal allocAmt = Decimal.valueOf(String.valueOf(alloc.get('allocatedAmount')));
                    Invoice__c inv = invMap.get(invId);
                    if (inv != null && allocAmt > inv.Balance_Due__c) {
                        throw new AuraHandledException(
                            'Allocation ' + allocAmt.setScale(2) + ' exceeds balance of ' +
                            inv.Name + ' (' + inv.Balance_Due__c.setScale(2) + ').'
                        );
                    }
                }
            }

            // Build the parent Collection__c — one record per physical payment
            Collection__c collection = buildCollection(data, accountId, totalAmount);

            Decimal unallocated = totalAmount - totalAllocated;
            Boolean hasOnAccount = unallocated > 0;
            Boolean isSingleFullPayment = (activeAllocations.size() == 1 && unallocated == 0);

            // If fully allocated to a single invoice, link it directly so the
            // existing OVE_Collection_TriggerHandler updates the invoice balance.
            // For multi-invoice or partial payments, we'll handle balance updates
            // manually via Collection_Allocation__c.
            if (isSingleFullPayment) {
                collection.Invoice__c = (Id) activeAllocations[0].get('invoiceId');
            } else if (activeAllocations.isEmpty()) {
                // Pure On Account — no allocations
                collection.Is_On_Account__c = true;
            } else if (hasOnAccount) {
                // Mixed — some allocated, remainder goes on account
                collection.Is_On_Account__c = true;
            }

            if (collection.Status__c == null) collection.Status__c = 'Collected';
            if (collection.Collection_Date__c == null) collection.Collection_Date__c = Date.today();

            insert collection;

            // Create child allocations + manually update invoice balances
            // (only for multi-invoice or partial cases — for single full payment
            // the trigger handler already deducted via Collection.Invoice__c)
            if (!activeAllocations.isEmpty() && !isSingleFullPayment) {
                List<Collection_Allocation__c> allocRecords = new List<Collection_Allocation__c>();
                Map<Id, Decimal> invoiceAllocAmounts = new Map<Id, Decimal>();

                for (Map<String, Object> alloc : activeAllocations) {
                    Id invId = (Id) alloc.get('invoiceId');
                    Decimal allocAmt = Decimal.valueOf(String.valueOf(alloc.get('allocatedAmount')));
                    allocRecords.add(new Collection_Allocation__c(
                        Collection__c = collection.Id,
                        Invoice__c = invId,
                        Allocated_Amount__c = allocAmt
                    ));
                    invoiceAllocAmounts.put(invId,
                        (invoiceAllocAmounts.containsKey(invId) ? invoiceAllocAmounts.get(invId) : 0) + allocAmt);
                }
                insert allocRecords;

                // Update each invoice balance by its total allocation
                List<Invoice__c> invoicesToUpdate = new List<Invoice__c>();
                for (Invoice__c inv : [
                    SELECT Id, Balance_Due__c, Status__c
                    FROM Invoice__c WHERE Id IN :invoiceAllocAmounts.keySet()
                ]) {
                    Decimal deduct = invoiceAllocAmounts.get(inv.Id);
                    Decimal newBalance = (inv.Balance_Due__c == null ? 0 : inv.Balance_Due__c) - deduct;
                    inv.Balance_Due__c = newBalance;
                    if (newBalance <= 0) {
                        inv.Payment_Status__c = 'Fully Paid';
                    } else {
                        inv.Payment_Status__c = 'Partially Paid';
                    }
                    invoicesToUpdate.add(inv);
                }
                if (!invoicesToUpdate.isEmpty()) update invoicesToUpdate;
            } else if (isSingleFullPayment) {
                // Trigger handler reduced balance but doesn't set Status — set it here
                Id invId = (Id) activeAllocations[0].get('invoiceId');
                Invoice__c inv = [SELECT Id, Balance_Due__c, Status__c FROM Invoice__c WHERE Id = :invId];
                if (inv.Balance_Due__c <= 0) {
                    inv.Payment_Status__c = 'Fully Paid';
                    update inv;
                }
                // Also create a Collection_Allocation__c record for traceability
                insert new Collection_Allocation__c(
                    Collection__c = collection.Id,
                    Invoice__c = invId,
                    Allocated_Amount__c = totalAmount
                );
            }

            return [
                SELECT Id, Name, Amount__c, Status__c, Is_On_Account__c,
                       Account__c, Invoice__c, Collection_Date__c
                FROM Collection__c WHERE Id = :collection.Id
            ];
        } catch (Exception e) {
            Database.rollback(sp);
            if (e instanceof AuraHandledException) {
                throw e;
            }
            AuraHandledException aex = new AuraHandledException(e.getMessage());
            aex.setMessage(e.getMessage());
            throw aex;
        }
    }

    private static Collection__c buildCollection(Map<String, Object> data, Id accountId, Decimal totalAmount) {
        Collection__c collection = new Collection__c();
        collection.Account__c = accountId;
        collection.Amount__c = totalAmount;
        collection.Payment_Mode__c = (String) data.get('paymentMode');
        collection.Notes__c = (String) data.get('remarks');
        // Auto-populate assignment fields with the current user
        collection.Salesperson__c = UserInfo.getUserId();
        collection.Collected_By__c = UserInfo.getUserId();
        if (data.get('visitId') != null) {
            collection.Visit__c = (Id) data.get('visitId');
        }
        if (data.get('chequeNumber') != null && String.isNotBlank((String) data.get('chequeNumber'))) {
            collection.Cheque_Number__c = (String) data.get('chequeNumber');
        }
        if (data.get('chequeDate') != null && String.isNotBlank(String.valueOf(data.get('chequeDate')))) {
            collection.Cheque_Date__c = Date.valueOf(String.valueOf(data.get('chequeDate')));
        }
        if (data.get('bankName') != null && String.isNotBlank((String) data.get('bankName'))) {
            collection.Bank_Name__c = (String) data.get('bankName');
        }
        if (data.get('upiReference') != null && String.isNotBlank((String) data.get('upiReference'))) {
            collection.UPI_Reference__c = (String) data.get('upiReference');
        }
        if (data.get('neftReference') != null && String.isNotBlank((String) data.get('neftReference'))) {
            collection.Transaction_Reference__c = (String) data.get('neftReference');
        }
        return collection;
    }

    @AuraEnabled
    public static Map<String, Decimal> getAgingSummary(Id accountId) {
        // Non-cacheable: aging buckets change after every collection
        return CollectionController.getAgingSummary(accountId);
    }

    @AuraEnabled
    public static List<Collection__c> getCollectionHistory(Id accountId) {
        // Non-cacheable: history changes immediately after creating a collection
        return CollectionController.getCollectionHistory(accountId);
    }
}