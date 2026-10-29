/**
 * @description Coverage for the Availability & Stock Depth activity: saving a
 *              capture stores the values, computes the below-min and price-
 *              compliance formula flags, and marks the visit complete; and the
 *              product list returns audited-category products with reference data.
 */
@IsTest
private class OVE_AvailabilityController_Test {

    @IsTest
    static void saveAvailability_capturesFlagsAndCompletesVisit() {
        Account outlet = TestDataFactory.createAndInsertAccount('Avail Outlet', 'Retailer');
        Product_Extension__c prod = TestDataFactory.createProduct('Avail Widget', 'AVW-1');
        prod.MRP__c = 10;
        prod.Min_Order_Qty__c = 24;
        prod.Is_Active__c = true;
        insert prod;
        Visit__c v = new Visit__c(
            Account__c = outlet.Id, Visit_Date__c = Date.today(), Visit_Status__c = 'Checked In',
            User__c = UserInfo.getUserId(), Check_In_Time__c = Datetime.now()
        );
        insert v;

        String json = JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'productId' => prod.Id, 'observedStock' => 5, 'sellingPrice' => 12,
                'systemStock' => 1000, 'rsp' => 10, 'minQty' => 24
            }
        });

        Test.startTest();
        OVE_AvailabilityController.saveAvailability(json, v.Id, outlet.Id);
        Test.stopTest();

        Availability_Check__c ac = [
            SELECT Observed_Stock__c, Shelf_Selling_Price__c, RSP_Snapshot__c,
                   Min_Qty_Snapshot__c, System_Stock__c, Below_Min_Stock__c, Price_Compliance__c
            FROM Availability_Check__c WHERE Visit__c = :v.Id LIMIT 1
        ];
        System.assertEquals(5, ac.Observed_Stock__c, 'observed stock stored');
        System.assertEquals(12, ac.Shelf_Selling_Price__c, 'selling price stored');
        System.assertEquals(10, ac.RSP_Snapshot__c, 'RSP snapshot stored');
        System.assertEquals(true, ac.Below_Min_Stock__c, '5 < 24 flags below-min');
        System.assertEquals('Over RSP', ac.Price_Compliance__c, '12 > 10 flags Over RSP');
        System.assertEquals(true,
            [SELECT Availability_Check_Completed__c FROM Visit__c WHERE Id = :v.Id].Availability_Check_Completed__c,
            'visit marked complete');
    }

    @IsTest
    static void searchAvailabilityProducts_findsAuditedCategoryProduct() {
        Product_Category__c cat = new Product_Category__c(Name = 'Biscuit', Category_Code__c = 'TST-BISC');
        insert cat;
        Product_Extension__c prod = TestDataFactory.createProduct('Test Biscuit', 'TB-1');
        prod.MRP__c = 25;
        prod.Min_Order_Qty__c = 12;
        prod.Is_Active__c = true;
        prod.Product_Category__c = cat.Id;
        insert prod;

        Test.startTest();
        List<Map<String, Object>> hits = OVE_AvailabilityController.searchAvailabilityProducts('Test Biscuit');
        List<Map<String, Object>> none = OVE_AvailabilityController.searchAvailabilityProducts('');
        Test.stopTest();

        System.assertEquals(0, none.size(), 'Blank term returns nothing');
        Boolean found = false;
        for (Map<String, Object> r : hits) {
            if (r.get('sku') == 'TB-1') {
                found = true;
                System.assertEquals(25, r.get('rsp'), 'RSP comes from product MRP');
                System.assertEquals(12, r.get('minQty'), 'min qty comes from product');
                System.assertEquals('Biscuit', r.get('category'), 'category name returned');
            }
        }
        System.assert(found, 'Search finds a product in an audited category');
    }

    @IsTest
    static void getAvailabilityData_rehydratesOnlyCapturedProducts() {
        Account outlet = TestDataFactory.createAndInsertAccount('Rehydrate Outlet', 'Retailer');
        Product_Extension__c prod = TestDataFactory.createProduct('Rehydrate Widget', 'RW-1');
        prod.MRP__c = 20; prod.Min_Order_Qty__c = 10; prod.Is_Active__c = true;
        insert prod;
        Visit__c v = new Visit__c(Account__c = outlet.Id, Visit_Date__c = Date.today(),
            Visit_Status__c = 'Checked In', User__c = UserInfo.getUserId(), Check_In_Time__c = Datetime.now());
        insert v;

        // Fresh visit -> nothing to rehydrate.
        System.assertEquals(0, OVE_AvailabilityController.getAvailabilityData(outlet.Id, v.Id).size(),
            'A fresh visit shows no added products');

        Test.startTest();
        OVE_AvailabilityController.saveAvailability(JSON.serialize(new List<Object>{
            new Map<String, Object>{ 'productId' => prod.Id, 'observedStock' => 3, 'sellingPrice' => 22,
                'rsp' => 20, 'minQty' => 10 } }), v.Id, outlet.Id);
        Test.stopTest();

        List<Map<String, Object>> rows = OVE_AvailabilityController.getAvailabilityData(outlet.Id, v.Id);
        System.assertEquals(1, rows.size(), 'Captured product is rehydrated');
        System.assertEquals(3, rows[0].get('observedStock'), 'prior observed stock returned');
        System.assertEquals(22, rows[0].get('sellingPrice'), 'prior selling price returned');
    }
}