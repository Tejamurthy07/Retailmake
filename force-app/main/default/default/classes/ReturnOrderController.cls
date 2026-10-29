/**
 * @description Controller for the Return Order LWC component.
 *              Manages sales returns including invoice lookup, line item retrieval
 *              with available return quantities, and return order creation with validation.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public with sharing class ReturnOrderController {

    // ── Get Account Invoices ────────────────────────────────────────────────────

    /**
     * @description Retrieves delivered/dispatched invoices for an account that are
     *              eligible for returns.
     * @param accountId The Account (outlet) Id.
     * @return List of Invoice__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<Invoice__c> getAccountInvoices(Id accountId) {
        // Secondary (retailer) invoices are booked as Draft — the sale is complete at billing,
        // goods handed over at the outlet — so Draft must be eligible for return, alongside the
        // primary delivered/dispatched statuses. Only Cancelled/Rejected are excluded.
        return [
            SELECT Id, Name, Invoice_Date__c, Total_Amount__c, Net_Amount__c,
                   Tax_Amount__c, Balance_Due__c, Status__c, Order_Type__c,
                   Sold_From_Distributor__c, Sales_Order__c, Sales_Order__r.Name,
                   Delivery_Date__c, GSTIN__c
            FROM Invoice__c
            WHERE Account__c = :accountId
            AND Status__c IN ('Draft', 'Confirmed', 'Delivered', 'Dispatched', 'Partially Returned')
            ORDER BY Invoice_Date__c DESC
            LIMIT 50
        ];
    }

    // ── Get Invoice Lines ───────────────────────────────────────────────────────

    /**
     * @description Retrieves line items for a given invoice, including quantities
     *              already returned so that the LWC can display available return quantity.
     * @param invoiceId The Invoice__c record Id.
     * @return List of maps containing invoice line data and already-returned quantities.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getInvoiceLines(Id invoiceId) {
        List<Map<String, Object>> results = new List<Map<String, Object>>();

        // Get invoice lines
        List<Invoice_Line__c> lines = [
            SELECT Id, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c,
                   Quantity__c, Unit_Price__c, Discount__c, Tax_Amount__c,
                   Line_Total__c, HSN_SAC_Code__c, Batch_No__c,
                   CGST__c, SGST__c, IGST__c
            FROM Invoice_Line__c
            WHERE Invoice__c = :invoiceId
            ORDER BY CreatedDate
        ];

        if (lines.isEmpty()) {
            return results;
        }

        // Collect invoice line Ids to query existing returns
        Set<Id> invoiceLineIds = new Set<Id>();
        for (Invoice_Line__c line : lines) {
            invoiceLineIds.add(line.Id);
        }

        // Get already-returned quantities grouped by invoice line
        Map<Id, Decimal> returnedQtyMap = new Map<Id, Decimal>();
        List<AggregateResult> returnAgg = [
            SELECT Invoice_Line__c lineId, SUM(Return_Quantity__c) totalReturned
            FROM Return_Line__c
            WHERE Invoice_Line__c IN :invoiceLineIds
            AND Return_Order__r.Status__c NOT IN ('Cancelled', 'Rejected')
            GROUP BY Invoice_Line__c
        ];
        for (AggregateResult ar : returnAgg) {
            Id lineId = (Id)ar.get('lineId');
            Decimal totalReturned = (Decimal)ar.get('totalReturned');
            returnedQtyMap.put(lineId, totalReturned != null ? totalReturned : 0);
        }

        // Build result maps
        for (Invoice_Line__c line : lines) {
            Map<String, Object> lineMap = new Map<String, Object>();
            lineMap.put('invoiceLineId', line.Id);
            lineMap.put('productId', line.Product_Ext__c);
            lineMap.put('productName', line.Product_Ext__r.Name);
            lineMap.put('productCode', line.Product_Ext__r.SKU_Code__c);
            lineMap.put('invoicedQty', line.Quantity__c);
            lineMap.put('unitPrice', line.Unit_Price__c);
            lineMap.put('discount', line.Discount__c);
            lineMap.put('taxAmount', line.Tax_Amount__c);
            lineMap.put('lineTotal', line.Line_Total__c);
            lineMap.put('hsnCode', line.HSN_SAC_Code__c);
            lineMap.put('batchNo', line.Batch_No__c);

            Decimal alreadyReturned = returnedQtyMap.containsKey(line.Id)
                ? returnedQtyMap.get(line.Id)
                : 0;
            Decimal invoicedQty = line.Quantity__c != null ? line.Quantity__c : 0;
            Decimal availableForReturn = invoicedQty - alreadyReturned;

            lineMap.put('alreadyReturned', alreadyReturned);
            lineMap.put('availableForReturn', availableForReturn > 0 ? availableForReturn : 0);

            results.add(lineMap);
        }

        return results;
    }

    // ── Create Return Order (JSON) ──────────────────────────────────────────────

    /**
     * @description Creates a Return Order from a JSON payload sent by the LWC component.
     *              Parses the JSON into Return_Order__c header and Return_Line__c items,
     *              then delegates to the typed createReturnOrderFromRecords method.
     * @param returnJson JSON string containing return order data.
     * @return The inserted Return_Order__c record with Id.
     */
    @AuraEnabled
    public static Return_Order__c createReturnOrder(String returnJson) {
        try {
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(returnJson);

            Id accountId = payload.get('accountId') != null ? (Id) String.valueOf(payload.get('accountId')) : null;
            Id invoiceId = payload.get('invoiceId') != null ? (Id) String.valueOf(payload.get('invoiceId')) : null;

            Return_Order__c returnOrder = new Return_Order__c();
            returnOrder.Account__c = accountId;
            if (payload.get('visitId') != null) {
                returnOrder.Visit__c = (String) payload.get('visitId');
            }
            if (invoiceId != null) {
                returnOrder.Invoice__c = invoiceId;
            }
            returnOrder.Notes__c = (String) payload.get('remarks');
            returnOrder.Return_Date__c = Date.today();
            returnOrder.Status__c = 'Draft';
            // A return booked against a retailer's invoice (in a visit or the returns screen) is a
            // SECONDARY return: retailer -> distributor. The engine restocks the distributor and
            // posts the retailer's credit note on approval.
            returnOrder.Return_Type__c = DMS_Constants.RETURN_TYPE_SECONDARY;

            // Servicing distributor: the invoice's source distributor, else the retailer's parent.
            Id distributorId = resolveDistributor(invoiceId, accountId);
            if (distributorId != null) {
                returnOrder.Returned_To_Distributor__c = distributorId;
            }

            List<Map<String, Object>> itemMaps = new List<Map<String, Object>>();
            List<Object> items = (List<Object>) payload.get('returnLines');
            if (items != null) {
                for (Object itemObj : items) {
                    itemMaps.add((Map<String, Object>) itemObj);
                }
            }

            // Resolve the batch's current expiry so the restocked snapshot keeps it (only when
            // still valid — a past expiry on a current stock row is blocked by validation).
            Set<Id> productIds = new Set<Id>();
            Set<String> batches = new Set<String>();
            for (Map<String, Object> item : itemMaps) {
                if (item.get('productId') != null) { productIds.add((Id) String.valueOf(item.get('productId'))); }
                String b = (String) item.get('batchNo');
                if (String.isNotBlank(b)) { batches.add(b); }
            }
            Map<String, Date> expiryByKey = resolveExpiry(distributorId, productIds, batches);

            List<Return_Line__c> returnLines = new List<Return_Line__c>();
            for (Map<String, Object> item : itemMaps) {
                Return_Line__c rl = new Return_Line__c();
                if (item.get('invoiceLineId') != null) {
                    rl.Invoice_Line__c = (String) item.get('invoiceLineId');
                }
                rl.Product_Ext__c = (String) item.get('productId');
                rl.Return_Quantity__c = toDecimal(item.get('returnQty'));
                rl.Return_Reason__c = (String) item.get('reason');
                String batchNo = (String) item.get('batchNo');
                rl.Batch_No__c = String.isBlank(batchNo) ? null : batchNo;
                Decimal amt = toDecimal(item.get('returnAmount'));
                Decimal qty = toDecimal(item.get('returnQty'));
                rl.Unit_Price__c = (amt != null && qty != null && qty > 0) ? (amt / qty) : null;
                if (rl.Product_Ext__c != null && String.isNotBlank(batchNo)) {
                    Date exp = expiryByKey.get(rl.Product_Ext__c + '|' + batchNo);
                    if (exp != null && exp >= Date.today()) { rl.Expiry_Date__c = exp; }
                }
                returnLines.add(rl);
            }

            Return_Order__c created = createReturnOrderFromRecords(returnOrder, returnLines);

            // Auto-approve: the field/returns-screen secondary return posts immediately — the
            // distributor is restocked and the retailer credit note is issued.
            update new Return_Order__c(Id = created.Id, Status__c = 'Approved');

            return created;
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /** Distributor the returned goods go back to: invoice's source distributor, else the retailer's parent. */
    private static Id resolveDistributor(Id invoiceId, Id accountId) {
        if (invoiceId != null) {
            for (Invoice__c inv : [SELECT Sold_From_Distributor__c FROM Invoice__c WHERE Id = :invoiceId LIMIT 1]) {
                if (inv.Sold_From_Distributor__c != null) { return inv.Sold_From_Distributor__c; }
            }
        }
        if (accountId != null) {
            for (Account a : [SELECT ParentId FROM Account WHERE Id = :accountId LIMIT 1]) {
                return a.ParentId;
            }
        }
        return null;
    }

    /** Current expiry per product|batch for the distributor, so a restocked batch keeps its expiry. */
    private static Map<String, Date> resolveExpiry(Id distributorId, Set<Id> productIds, Set<String> batches) {
        Map<String, Date> out = new Map<String, Date>();
        if (distributorId == null || productIds.isEmpty() || batches.isEmpty()) {
            return out;
        }
        for (Distributor_Stock__c ds : [
            SELECT Product_Ext__c, Batch_No__c, Expiry_Date__c
            FROM Distributor_Stock__c
            WHERE Account__c = :distributorId AND Product_Ext__c IN :productIds
              AND Batch_No__c IN :batches AND Is_Current__c = true AND Expiry_Date__c != null
        ]) {
            out.put(ds.Product_Ext__c + '|' + ds.Batch_No__c, ds.Expiry_Date__c);
        }
        return out;
    }

    private static Decimal toDecimal(Object value) {
        if (value == null) return null;
        if (value instanceof Decimal) return (Decimal) value;
        if (value instanceof Integer) return Decimal.valueOf((Integer) value);
        if (value instanceof Long) return Decimal.valueOf((Long) value);
        if (value instanceof Double) return Decimal.valueOf((Double) value);
        return Decimal.valueOf(String.valueOf(value));
    }

    // ── Create Return Order (typed) ─────────────────────────────────────────────

    /**
     * @description Creates a Return Order with its line items after validating
     *              that return quantities do not exceed available quantities.
     *              Uses savepoint for transactional integrity.
     * @param returnOrder The Return_Order__c header record.
     * @param returnLines List of Return_Line__c records.
     * @return The inserted Return_Order__c record with Id.
     */
    public static Return_Order__c createReturnOrderFromRecords(Return_Order__c returnOrder, List<Return_Line__c> returnLines) {
        Savepoint sp = Database.setSavepoint();
        try {
            // Validate inputs
            if (returnLines == null || returnLines.isEmpty()) {
                throw new AuraHandledException('At least one return line item is required.');
            }

            // Validate return quantities against available quantities
            Set<Id> invoiceLineIds = new Set<Id>();
            for (Return_Line__c rl : returnLines) {
                if (rl.Invoice_Line__c != null) {
                    invoiceLineIds.add(rl.Invoice_Line__c);
                }
            }

            // Get invoiced quantities
            Map<Id, Decimal> invoicedQtyMap = new Map<Id, Decimal>();
            if (!invoiceLineIds.isEmpty()) {
                List<Invoice_Line__c> invoiceLines = [
                    SELECT Id, Quantity__c
                    FROM Invoice_Line__c
                    WHERE Id IN :invoiceLineIds
                ];
                for (Invoice_Line__c il : invoiceLines) {
                    invoicedQtyMap.put(il.Id, il.Quantity__c != null ? il.Quantity__c : 0);
                }
            }

            // Get already-returned quantities
            Map<Id, Decimal> returnedQtyMap = new Map<Id, Decimal>();
            if (!invoiceLineIds.isEmpty()) {
                List<AggregateResult> returnAgg = [
                    SELECT Invoice_Line__c lineId, SUM(Return_Quantity__c) totalReturned
                    FROM Return_Line__c
                    WHERE Invoice_Line__c IN :invoiceLineIds
                    AND Return_Order__r.Status__c NOT IN ('Cancelled', 'Rejected')
                    GROUP BY Invoice_Line__c
                ];
                for (AggregateResult ar : returnAgg) {
                    Id lineId = (Id)ar.get('lineId');
                    Decimal totalReturned = (Decimal)ar.get('totalReturned');
                    returnedQtyMap.put(lineId, totalReturned != null ? totalReturned : 0);
                }
            }

            // Validate each return line
            for (Return_Line__c rl : returnLines) {
                if (rl.Return_Quantity__c == null || rl.Return_Quantity__c <= 0) {
                    throw new AuraHandledException('Return quantity must be greater than zero.');
                }

                if (rl.Invoice_Line__c != null) {
                    Decimal invoicedQty = invoicedQtyMap.containsKey(rl.Invoice_Line__c)
                        ? invoicedQtyMap.get(rl.Invoice_Line__c) : 0;
                    Decimal alreadyReturned = returnedQtyMap.containsKey(rl.Invoice_Line__c)
                        ? returnedQtyMap.get(rl.Invoice_Line__c) : 0;
                    Decimal available = invoicedQty - alreadyReturned;

                    if (rl.Return_Quantity__c > available) {
                        throw new AuraHandledException(
                            'Return quantity (' + String.valueOf(rl.Return_Quantity__c) +
                            ') exceeds available quantity (' + String.valueOf(available) +
                            ') for invoice line ' + rl.Invoice_Line__c + '.'
                        );
                    }
                }

                if (String.isBlank(rl.Return_Reason__c)) {
                    throw new AuraHandledException('Return reason is required for all line items.');
                }
            }

            // Set defaults on the return order
            if (returnOrder.Return_Date__c == null) {
                returnOrder.Return_Date__c = Date.today();
            }
            if (returnOrder.Status__c == null) {
                returnOrder.Status__c = 'Draft';
            }

            // Aggregate qty + value from the lines onto the header BEFORE insert: the header
            // Return_Quantity__c must be > 0 (OMS_ReturnOrder_TriggerHandler.validateReturnQuantity),
            // and Return_Amount__c is the credit-note amount posted to the account on approval.
            Decimal totalQty = 0;
            Decimal totalReturnValue = 0;
            for (Return_Line__c rl : returnLines) {
                Decimal q = rl.Return_Quantity__c != null ? rl.Return_Quantity__c : 0;
                totalQty += q;
                if (rl.Unit_Price__c != null) {
                    rl.Line_Total__c = rl.Unit_Price__c * q;
                    totalReturnValue += rl.Line_Total__c;
                }
            }
            returnOrder.Return_Quantity__c = totalQty;
            returnOrder.Return_Amount__c = totalReturnValue;
            returnOrder.Total_Return_Amount__c = totalReturnValue;
            returnOrder.Total_Return_Value__c = totalReturnValue;
            returnOrder.Total_Items__c = returnLines.size();

            insert returnOrder;

            for (Return_Line__c rl : returnLines) {
                rl.Return_Order__c = returnOrder.Id;
            }
            insert returnLines;

            return [
                SELECT Id, Name, Return_Date__c, Status__c, Account__c, Account__r.Name,
                       Invoice__c, Invoice__r.Name, Total_Return_Value__c, Total_Items__c,
                       Return_Reason__c
                FROM Return_Order__c
                WHERE Id = :returnOrder.Id
                LIMIT 1
            ];
        } catch (AuraHandledException ahe) {
            Database.rollback(sp);
            throw ahe;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException(e.getMessage());
        }
    }
}