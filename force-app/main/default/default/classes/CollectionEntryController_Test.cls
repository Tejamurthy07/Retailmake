@IsTest
private class CollectionEntryController_Test {

    @TestSetup
    static void setup() {
        Account acc = TestDataFactory.createAndInsertAccount('Test Outlet', 'Retailer');

        // Create a Sales Order (required for Invoice)
        Sales_Order__c so = TestDataFactory.createSalesOrder(acc.Id, UserInfo.getUserId(), null);
        insert so;

        // Create invoices with outstanding balances
        Invoice__c inv1 = TestDataFactory.createInvoice(so.Id, acc.Id);
        inv1.Status__c = 'Confirmed';
        inv1.Balance_Due__c = 10000;
        inv1.Net_Amount__c = 10000;
        inv1.Total_Amount__c = 10000;

        Invoice__c inv2 = TestDataFactory.createInvoice(so.Id, acc.Id);
        inv2.Status__c = 'Confirmed';
        inv2.Balance_Due__c = 5000;
        inv2.Net_Amount__c = 5000;
        inv2.Total_Amount__c = 5000;

        Invoice__c inv3 = TestDataFactory.createInvoice(so.Id, acc.Id);
        inv3.Status__c = 'Confirmed';
        inv3.Balance_Due__c = 8000;
        inv3.Net_Amount__c = 8000;
        inv3.Total_Amount__c = 8000;

        insert new List<Invoice__c>{ inv1, inv2, inv3 };
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    static Account getTestAccount() {
        return [SELECT Id FROM Account WHERE Name = 'Test Outlet' LIMIT 1];
    }

    static List<Invoice__c> getTestInvoices() {
        return [SELECT Id, Name, Balance_Due__c FROM Invoice__c ORDER BY Balance_Due__c DESC];
    }

    // ── getOutstandingInvoices ────────────────────────────────────────────────

    @IsTest
    static void testGetOutstandingInvoices() {
        Account acc = getTestAccount();

        Test.startTest();
        List<Invoice__c> invoices = CollectionEntryController.getOutstandingInvoices(acc.Id);
        Test.stopTest();

        System.assert(invoices != null, 'Outstanding invoices should not be null');
        System.assert(invoices.size() >= 1, 'Should return at least one outstanding invoice');
    }

    // ── createCollection: single invoice full payment ────────────────────────

    @IsTest
    static void testCreateCollectionSingleInvoice() {
        Account acc = getTestAccount();
        List<Invoice__c> invoices = getTestInvoices();
        Invoice__c inv = invoices[0]; // Balance_Due__c = 10000

        Map<String, Object> payload = new Map<String, Object>{
            'accountId' => acc.Id,
            'amount' => inv.Balance_Due__c,
            'paymentMode' => 'Cash',
            'remarks' => 'Full payment test',
            'allocations' => new List<Object>{
                new Map<String, Object>{
                    'invoiceId' => inv.Id,
                    'allocatedAmount' => inv.Balance_Due__c
                }
            }
        };

        Test.startTest();
        Collection__c result = CollectionEntryController.createCollection(JSON.serialize(payload));
        Test.stopTest();

        System.assertNotEquals(null, result, 'Collection should be created');
        System.assertNotEquals(null, result.Id, 'Collection should have an Id');
        System.assertEquals(inv.Balance_Due__c, result.Amount__c, 'Amount should match');

        // Verify allocation record was created
        List<Collection_Allocation__c> allocs = [
            SELECT Id, Allocated_Amount__c, Invoice__c
            FROM Collection_Allocation__c
            WHERE Collection__c = :result.Id
        ];
        System.assertEquals(1, allocs.size(), 'Should have one allocation record');
        System.assertEquals(inv.Balance_Due__c, allocs[0].Allocated_Amount__c, 'Allocation amount should match');
    }

    // ── createCollection: multi-invoice payment ──────────────────────────────

    @IsTest
    static void testCreateCollectionMultiInvoice() {
        Account acc = getTestAccount();
        List<Invoice__c> invoices = getTestInvoices();
        // Allocate across two invoices
        Invoice__c inv1 = invoices[0]; // 10000
        Invoice__c inv2 = invoices[1]; // 8000

        Decimal alloc1 = 6000;
        Decimal alloc2 = 4000;

        Map<String, Object> payload = new Map<String, Object>{
            'accountId' => acc.Id,
            'amount' => alloc1 + alloc2,
            'paymentMode' => 'Cheque',
            'chequeNumber' => 'CHQ-12345',
            'chequeDate' => String.valueOf(Date.today()),
            'bankName' => 'Test Bank',
            'remarks' => 'Multi-invoice test',
            'allocations' => new List<Object>{
                new Map<String, Object>{
                    'invoiceId' => inv1.Id,
                    'allocatedAmount' => alloc1
                },
                new Map<String, Object>{
                    'invoiceId' => inv2.Id,
                    'allocatedAmount' => alloc2
                }
            }
        };

        Test.startTest();
        Collection__c result = CollectionEntryController.createCollection(JSON.serialize(payload));
        Test.stopTest();

        System.assertNotEquals(null, result.Id, 'Collection should be created');
        System.assertEquals(alloc1 + alloc2, result.Amount__c, 'Total amount should match');

        // Verify two allocation records
        List<Collection_Allocation__c> allocs = [
            SELECT Id FROM Collection_Allocation__c WHERE Collection__c = :result.Id
        ];
        System.assertEquals(2, allocs.size(), 'Should have two allocation records');

        // Verify invoice balances were reduced
        Invoice__c updatedInv1 = [SELECT Balance_Due__c FROM Invoice__c WHERE Id = :inv1.Id];
        System.assertEquals(inv1.Balance_Due__c - alloc1, updatedInv1.Balance_Due__c,
            'Invoice 1 balance should be reduced by allocation');
    }

    // ── createCollection: on-account (no allocations) ────────────────────────

    @IsTest
    static void testCreateCollectionOnAccount() {
        Account acc = getTestAccount();

        Map<String, Object> payload = new Map<String, Object>{
            'accountId' => acc.Id,
            'amount' => 3000,
            'paymentMode' => 'Cash',
            'remarks' => 'On account credit',
            'allocations' => new List<Object>()
        };

        Test.startTest();
        Collection__c result = CollectionEntryController.createCollection(JSON.serialize(payload));
        Test.stopTest();

        System.assertNotEquals(null, result.Id, 'Collection should be created');
        System.assertEquals(true, result.Is_On_Account__c, 'Should be flagged as on-account');
        System.assertEquals(3000, result.Amount__c, 'Amount should be 3000');
    }

    // ── createCollection: partial allocation with on-account remainder ────────

    @IsTest
    static void testCreateCollectionPartialWithOnAccount() {
        Account acc = getTestAccount();
        List<Invoice__c> invoices = getTestInvoices();
        Invoice__c inv = invoices[0]; // 10000

        // Pay 15000 total, allocate only 8000 to invoice, rest on-account
        Map<String, Object> payload = new Map<String, Object>{
            'accountId' => acc.Id,
            'amount' => 15000,
            'paymentMode' => 'UPI',
            'upiReference' => 'UPI-REF-001',
            'remarks' => 'Partial with on-account',
            'allocations' => new List<Object>{
                new Map<String, Object>{
                    'invoiceId' => inv.Id,
                    'allocatedAmount' => 8000
                }
            }
        };

        Test.startTest();
        Collection__c result = CollectionEntryController.createCollection(JSON.serialize(payload));
        Test.stopTest();

        System.assertNotEquals(null, result.Id, 'Collection should be created');
        System.assertEquals(true, result.Is_On_Account__c, 'Should be on-account for remainder');
    }

    // ── createCollection: NEFT reference ─────────────────────────────────────

    @IsTest
    static void testCreateCollectionWithNeftReference() {
        Account acc = getTestAccount();
        List<Invoice__c> invoices = getTestInvoices();
        Invoice__c inv = invoices[2]; // 5000

        Map<String, Object> payload = new Map<String, Object>{
            'accountId' => acc.Id,
            'amount' => 2000,
            'paymentMode' => 'NEFT',
            'neftReference' => 'NEFT-REF-9999',
            'remarks' => 'NEFT payment',
            'allocations' => new List<Object>{
                new Map<String, Object>{
                    'invoiceId' => inv.Id,
                    'allocatedAmount' => 2000
                }
            }
        };

        Test.startTest();
        Collection__c result = CollectionEntryController.createCollection(JSON.serialize(payload));
        Test.stopTest();

        System.assertNotEquals(null, result.Id, 'Collection should be created');
    }

    // ── createCollection: validation - zero amount ───────────────────────────

    @IsTest
    static void testCreateCollectionZeroAmount() {
        Account acc = getTestAccount();

        Map<String, Object> payload = new Map<String, Object>{
            'accountId' => acc.Id,
            'amount' => 0,
            'paymentMode' => 'Cash',
            'allocations' => new List<Object>()
        };

        Test.startTest();
        try {
            CollectionEntryController.createCollection(JSON.serialize(payload));
            System.assert(false, 'Should have thrown AuraHandledException for zero amount');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e);
        }
        Test.stopTest();
    }

    // ── createCollection: validation - negative amount ───────────────────────

    @IsTest
    static void testCreateCollectionNegativeAmount() {
        Account acc = getTestAccount();

        Map<String, Object> payload = new Map<String, Object>{
            'accountId' => acc.Id,
            'amount' => -500,
            'paymentMode' => 'Cash',
            'allocations' => new List<Object>()
        };

        Test.startTest();
        try {
            CollectionEntryController.createCollection(JSON.serialize(payload));
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e);
        }
        Test.stopTest();
    }

    // ── createCollection: validation - allocation exceeds collection amount ──

    @IsTest
    static void testCreateCollectionAllocationExceedsTotal() {
        Account acc = getTestAccount();
        List<Invoice__c> invoices = getTestInvoices();
        Invoice__c inv = invoices[0];

        Map<String, Object> payload = new Map<String, Object>{
            'accountId' => acc.Id,
            'amount' => 5000,
            'paymentMode' => 'Cash',
            'allocations' => new List<Object>{
                new Map<String, Object>{
                    'invoiceId' => inv.Id,
                    'allocatedAmount' => 7000
                }
            }
        };

        Test.startTest();
        try {
            CollectionEntryController.createCollection(JSON.serialize(payload));
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e);
        }
        Test.stopTest();
    }

    // ── createCollection: validation - allocation exceeds invoice balance ────

    @IsTest
    static void testCreateCollectionAllocationExceedsBalance() {
        Account acc = getTestAccount();
        List<Invoice__c> invoices = getTestInvoices();
        Invoice__c inv = invoices[2]; // 5000 balance

        Map<String, Object> payload = new Map<String, Object>{
            'accountId' => acc.Id,
            'amount' => 20000,
            'paymentMode' => 'Cash',
            'allocations' => new List<Object>{
                new Map<String, Object>{
                    'invoiceId' => inv.Id,
                    'allocatedAmount' => 6000
                }
            }
        };

        Test.startTest();
        try {
            CollectionEntryController.createCollection(JSON.serialize(payload));
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e);
        }
        Test.stopTest();
    }

    // ── createCollection: null amount ────────────────────────────────────────

    @IsTest
    static void testCreateCollectionNullAmount() {
        Account acc = getTestAccount();

        Map<String, Object> payload = new Map<String, Object>{
            'accountId' => acc.Id,
            'paymentMode' => 'Cash',
            'allocations' => new List<Object>()
        };

        Test.startTest();
        try {
            CollectionEntryController.createCollection(JSON.serialize(payload));
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e);
        }
        Test.stopTest();
    }

    // ── getAgingSummary ──────────────────────────────────────────────────────

    @IsTest
    static void testGetAgingSummary() {
        Account acc = getTestAccount();

        Test.startTest();
        Map<String, Decimal> aging = CollectionEntryController.getAgingSummary(acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, aging, 'Aging summary should not be null');
        System.assert(aging.containsKey('total'), 'Should contain total key');
        System.assert(aging.get('total') >= 0, 'Total should be non-negative');
    }

    // ── getCollectionHistory ─────────────────────────────────────────────────

    @IsTest
    static void testGetCollectionHistory() {
        Account acc = getTestAccount();

        // Create a collection first
        Invoice__c inv = getTestInvoices()[0];
        Collection__c col = TestDataFactory.createCollection(acc.Id, inv.Id, 1000);
        insert col;

        Test.startTest();
        List<Collection__c> history = CollectionEntryController.getCollectionHistory(acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, history, 'Collection history should not be null');
        System.assert(history.size() >= 1, 'Should have at least one collection record');
    }

    // ── getCollectionHistory: empty ──────────────────────────────────────────

    @IsTest
    static void testGetCollectionHistoryEmpty() {
        Account newAcc = TestDataFactory.createAndInsertAccount('Empty Outlet', 'Retailer');

        Test.startTest();
        List<Collection__c> history = CollectionEntryController.getCollectionHistory(newAcc.Id);
        Test.stopTest();

        System.assertNotEquals(null, history, 'Collection history should not be null');
        System.assertEquals(0, history.size(), 'Should have no collection records');
    }

    // ── createCollection: allocations with zero-amount entries filtered out ──

    @IsTest
    static void testCreateCollectionWithZeroAllocationsFiltered() {
        Account acc = getTestAccount();
        List<Invoice__c> invoices = getTestInvoices();
        Invoice__c inv = invoices[0]; // 10000

        Map<String, Object> payload = new Map<String, Object>{
            'accountId' => acc.Id,
            'amount' => 5000,
            'paymentMode' => 'Cash',
            'allocations' => new List<Object>{
                new Map<String, Object>{
                    'invoiceId' => inv.Id,
                    'allocatedAmount' => 5000
                },
                new Map<String, Object>{
                    'invoiceId' => invoices[1].Id,
                    'allocatedAmount' => 0
                }
            }
        };

        Test.startTest();
        Collection__c result = CollectionEntryController.createCollection(JSON.serialize(payload));
        Test.stopTest();

        System.assertNotEquals(null, result.Id, 'Collection should be created');
    }
}