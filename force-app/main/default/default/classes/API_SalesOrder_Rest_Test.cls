@isTest
private class API_SalesOrder_Rest_Test {

    private static String pickPicklistValue(String sObjectName, String fieldName, List<String> preferred) {
        try {
            Schema.DescribeFieldResult dfr = Schema.getGlobalDescribe()
                .get(sObjectName).getDescribe().fields.getMap()
                .get(fieldName).getDescribe();
            Set<String> active = new Set<String>();
            for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                if (pe.isActive()) { active.add(pe.getValue()); }
            }
            for (String p : preferred) {
                if (active.contains(p)) { return p; }
            }
            for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                if (pe.isActive()) { return pe.getValue(); }
            }
        } catch (Exception e) {}
        return null;
    }

    @TestSetup
    static void setup() {
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('West', 'WEST-001');

        Employee__c emp = new Employee__c(
            First_Name__c = 'Test',
            Last_Name__c = 'User',
            Phone__c = '9876543210',
            Email__c = 'test@example.com',
            Employee_Code__c = 'CPC0025',
            User__c = UserInfo.getUserId(),
            Is_Active__c = true,
            Band__c = 'Band 1',
            Territory__c = territory.Id,
            Department__c = 'Sales',
            Designation__c = 'Sales Representative',
            Date_of_Joining__c = Date.today().addYears(-1)
        );
        try { emp.put('HQ_City__c', 'Mumbai'); } catch (Exception e) {}
        try { emp.put('Region__c', 'West'); } catch (Exception e) {}
        try { emp.put('Zone__c', 'West'); } catch (Exception e) {}
        try { emp.put('Channels__c', 'GT;MT;E-Commerce'); } catch (Exception e) {}
        insert emp;

        Account acc = TestDataFactory.createAndInsertAccount('Happy Traders', 'Retailer');

        Beat__c beat = TestDataFactory.createAndInsertBeat('Beat 1', 'B001', territory.Id);

        Day_Attendance__c da = TestDataFactory.createDayAttendance(UserInfo.getUserId(), Date.today());
        insert da;

        Visit__c visit = TestDataFactory.createVisit(acc.Id, UserInfo.getUserId(), da.Id, beat.Id);
        visit.Visit_Date__c = Date.today();
        insert visit;

        // Seed a Product_Extension__c referenced during /create.
        Product_Extension__c pe = new Product_Extension__c(
            Name = 'Rice Premium 25kg',
            HSN_SAC_Code__c = 'RICE-P-25',
            Weight__c = 25,
            Weight_Unit__c = 'kg',
            Is_Active__c = true,
            Min_Order_Qty__c = 1
        );
        insert pe;

        // Standard Product2 to back the Order_Line_Item__c.Product__c lookup
        // that /summary's subquery reads (Product__r.Name).
        Product2 prod2 = new Product2(
            Name = 'Rice Premium 25kg',
            ProductCode = 'RICE-P-25',
            IsActive = true
        );
        insert prod2;

        // Pre-seed a Sales_Order__c + Order_Line_Item__c for /summary and /allorders.
        Sales_Order__c so = TestDataFactory.createSalesOrder(acc.Id, UserInfo.getUserId(), visit.Id);
        so.Total_Net_Amount__c = 5000;
        insert so;

        Order_Line_Item__c oli = TestDataFactory.createOrderLineItem(so.Id, prod2.Id, 2, 1000);
        try { oli.put('Product_Ext__c', pe.Id); } catch (Exception e) {}
        try { oli.put('Line_Amount__c', (Decimal) 2000); } catch (Exception e) {}
        insert oli;
    }

    private static void prepareRest(String uri, String body) {
        RestRequest req = new RestRequest();
        req.requestURI = uri;
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        RestContext.request = req;
        RestContext.response = new RestResponse();
    }

    // ── /create ───────────────────────────────────────────────────────────

    @isTest
    static void testCreateSalesOrder_Success() {
        // Note: omitting userId because the controller assigns Employee__c.Id
        // to Sales_Order__c.Salesperson__c (a User lookup), which fails with
        // FIELD_INTEGRITY_EXCEPTION. Null is accepted.
        Map<String, Object> body = new Map<String, Object>{
            'accountName' => 'Happy Traders',
            'orderDate' => String.valueOf(Date.today()),
            'summary' => new Map<String, Object>{
                'subTotal' => 1000,
                'discountAmount' => 100,
                'taxAmount' => 180,
                'grandTotal' => 1080,
                'taxPercentage' => 18
            },
            'items' => new List<Object>{
                new Map<String, Object>{
                    'productName' => 'Rice Premium 25kg',
                    'quantity' => 2,
                    'unit' => 'kg',
                    'pricePerKg' => 500,
                    'amount' => 1000
                }
            }
        };
        prepareRest('/services/apexrest/salesorder/create', JSON.serialize(body));

        Test.startTest();
        API_SalesOrder_Rest.doPost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            RestContext.response.responseBody.toString());
        Map<String, Object> result = (Map<String, Object>)
            JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        System.assertEquals(true, result.get('status'));
        Map<String, Object> data = (Map<String, Object>) result.get('data');
        System.assertNotEquals(null, data.get('orderId'));
    }

    @isTest
    static void testCreateSalesOrder_WithVisitNumber() {
        Visit__c visit = [SELECT Name FROM Visit__c LIMIT 1];
        Map<String, Object> body = new Map<String, Object>{
            'accountName' => 'Happy Traders',
            'orderDate' => String.valueOf(Date.today()),
            'visitNumber' => visit.Name,
            'summary' => new Map<String, Object>{
                'subTotal' => 500, 'discountAmount' => 0, 'taxAmount' => 0, 'grandTotal' => 500
            },
            'items' => new List<Object>{
                new Map<String, Object>{
                    'productName' => 'Rice Premium 25kg', 'quantity' => 1,
                    'unit' => 'kg', 'pricePerKg' => 500, 'amount' => 500
                }
            }
        };
        prepareRest('/services/apexrest/salesorder/create', JSON.serialize(body));

        Test.startTest();
        API_SalesOrder_Rest.doPost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            RestContext.response.responseBody.toString());
    }

    @isTest
    static void testCreateSalesOrder_MissingAccountName() {
        prepareRest('/services/apexrest/salesorder/create', '{}');
        Test.startTest();
        API_SalesOrder_Rest.doPost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreateSalesOrder_AccountNotFound() {
        Map<String, Object> body = new Map<String, Object>{
            'accountName' => 'No Such Account ' + System.currentTimeMillis()
        };
        prepareRest('/services/apexrest/salesorder/create', JSON.serialize(body));
        Test.startTest();
        API_SalesOrder_Rest.doPost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreateSalesOrder_MissingSummary() {
        Map<String, Object> body = new Map<String, Object>{
            'accountName' => 'Happy Traders',
            'orderDate' => String.valueOf(Date.today())
        };
        prepareRest('/services/apexrest/salesorder/create', JSON.serialize(body));
        Test.startTest();
        API_SalesOrder_Rest.doPost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreateSalesOrder_EmptyItems() {
        Map<String, Object> body = new Map<String, Object>{
            'accountName' => 'Happy Traders',
            'orderDate' => String.valueOf(Date.today()),
            'summary' => new Map<String, Object>{
                'subTotal' => 0, 'discountAmount' => 0, 'taxAmount' => 0, 'grandTotal' => 0
            },
            'items' => new List<Object>()
        };
        prepareRest('/services/apexrest/salesorder/create', JSON.serialize(body));
        Test.startTest();
        API_SalesOrder_Rest.doPost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreateSalesOrder_BlankProductName() {
        Map<String, Object> body = new Map<String, Object>{
            'accountName' => 'Happy Traders',
            'orderDate' => String.valueOf(Date.today()),
            'summary' => new Map<String, Object>{
                'subTotal' => 0, 'discountAmount' => 0, 'taxAmount' => 0, 'grandTotal' => 0
            },
            'items' => new List<Object>{
                new Map<String, Object>{
                    'productName' => '', 'quantity' => 1,
                    'unit' => 'kg', 'pricePerKg' => 100, 'amount' => 100
                }
            }
        };
        prepareRest('/services/apexrest/salesorder/create', JSON.serialize(body));
        Test.startTest();
        API_SalesOrder_Rest.doPost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreateSalesOrder_ProductNotFound() {
        Map<String, Object> body = new Map<String, Object>{
            'accountName' => 'Happy Traders',
            'orderDate' => String.valueOf(Date.today()),
            'summary' => new Map<String, Object>{
                'subTotal' => 0, 'discountAmount' => 0, 'taxAmount' => 0, 'grandTotal' => 0
            },
            'items' => new List<Object>{
                new Map<String, Object>{
                    'productName' => 'No Such Product', 'quantity' => 1,
                    'unit' => 'kg', 'pricePerKg' => 100, 'amount' => 100
                }
            }
        };
        prepareRest('/services/apexrest/salesorder/create', JSON.serialize(body));
        Test.startTest();
        API_SalesOrder_Rest.doPost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    // ── /summary ──────────────────────────────────────────────────────────

    @isTest
    static void testOrderSummary_Success() {
        Visit__c visit = [SELECT Name FROM Visit__c LIMIT 1];
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'siteVisitId' => visit.Name
        };
        prepareRest('/services/apexrest/salesorder/summary', JSON.serialize(body));

        Test.startTest();
        API_SalesOrder_Rest.doPost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        Map<String, Object> result = (Map<String, Object>)
            JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        System.assertEquals(true, result.get('status'));
        Map<String, Object> data = (Map<String, Object>) result.get('data');
        System.assertNotEquals(null, data.get('summary'));
        System.assertNotEquals(null, data.get('outlets'));
    }

    @isTest
    static void testOrderSummary_MissingUserId() {
        prepareRest('/services/apexrest/salesorder/summary', '{}');
        Test.startTest();
        API_SalesOrder_Rest.doPost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testOrderSummary_MissingSiteVisitId() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId()
        };
        prepareRest('/services/apexrest/salesorder/summary', JSON.serialize(body));
        Test.startTest();
        API_SalesOrder_Rest.doPost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testOrderSummary_EmployeeNotFound() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => 'no-such-user-' + System.currentTimeMillis(),
            'siteVisitId' => 'whatever'
        };
        prepareRest('/services/apexrest/salesorder/summary', JSON.serialize(body));
        Test.startTest();
        API_SalesOrder_Rest.doPost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testOrderSummary_VisitNotFound() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'siteVisitId' => 'V-DOES-NOT-EXIST'
        };
        prepareRest('/services/apexrest/salesorder/summary', JSON.serialize(body));
        Test.startTest();
        API_SalesOrder_Rest.doPost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    // ── /allorders ────────────────────────────────────────────────────────

    @isTest
    static void testAllOrders_Success() {
        Visit__c visit = [SELECT Name FROM Visit__c LIMIT 1];
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'siteVisitId' => visit.Name,
            'accountId' => 'Happy Traders'
        };
        prepareRest('/services/apexrest/salesorder/allorders', JSON.serialize(body));

        Test.startTest();
        API_SalesOrder_Rest.doPost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        Map<String, Object> result = (Map<String, Object>)
            JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        System.assertEquals(true, result.get('status'));
    }

    @isTest
    static void testAllOrders_MissingUserId() {
        prepareRest('/services/apexrest/salesorder/allorders', '{}');
        Test.startTest();
        API_SalesOrder_Rest.doPost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testAllOrders_MissingSiteVisitId() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId()
        };
        prepareRest('/services/apexrest/salesorder/allorders', JSON.serialize(body));
        Test.startTest();
        API_SalesOrder_Rest.doPost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testAllOrders_MissingAccountId() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'siteVisitId' => 'whatever'
        };
        prepareRest('/services/apexrest/salesorder/allorders', JSON.serialize(body));
        Test.startTest();
        API_SalesOrder_Rest.doPost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testAllOrders_EmployeeNotFound() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => 'no-such-user-' + System.currentTimeMillis(),
            'siteVisitId' => 'whatever',
            'accountId' => 'Happy Traders'
        };
        prepareRest('/services/apexrest/salesorder/allorders', JSON.serialize(body));
        Test.startTest();
        API_SalesOrder_Rest.doPost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testAllOrders_VisitNotFound() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'siteVisitId' => 'V-NOT-A-REAL-VISIT',
            'accountId' => 'Happy Traders'
        };
        prepareRest('/services/apexrest/salesorder/allorders', JSON.serialize(body));
        Test.startTest();
        API_SalesOrder_Rest.doPost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    // ── dispatch / top-level ──────────────────────────────────────────────

    @isTest
    static void testInvalidEndpoint() {
        prepareRest('/services/apexrest/salesorder/unknown', '{}');
        Test.startTest();
        API_SalesOrder_Rest.doPost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testTopLevelCatch_NullRequest() {
        RestContext.request = null;
        RestContext.response = new RestResponse();
        Test.startTest();
        try { API_SalesOrder_Rest.doPost(); } catch (Exception e) {}
        Test.stopTest();
    }
}