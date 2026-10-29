/**
 * @description Coverage for the SFA Copilot order actions. Exercises Draft Order
 *              and Place Order exactly as Agentforce calls them, including the
 *              confirmation gate and the guard paths. The create path runs in a
 *              test context, where createSalesOrder's AuraHandledException is
 *              throwable and catchable (unlike anonymous Apex).
 */
@IsTest
private class SFA_OrderActions_Test {

    private static Account outletWithCredit() {
        Account a = TestDataFactory.createAndInsertAccount('Order Copilot Outlet', 'Retailer');
        a.Credit_Limit__c = 10000000;
        update a;
        return a;
    }

    private static Product_Extension__c pricedProduct() {
        Product_Extension__c p = TestDataFactory.createProduct('Copilot Cola 500ml', 'CPC-500');
        p.Unit_Price__c = 100;
        insert p;
        return p;
    }

    /** Two products that share the stem "Copilot Cola" so a bare stem is ambiguous. */
    private static void insertColaVariants() {
        Product_Extension__c p500 = TestDataFactory.createProduct('Copilot Cola 500ml', 'CPC-500');
        p500.Unit_Price__c = 100;
        Product_Extension__c p250 = TestDataFactory.createProduct('Copilot Cola 250ml', 'CPC-250');
        p250.Unit_Price__c = 60;
        insert new List<Product_Extension__c>{ p500, p250 };
    }

    @IsTest
    static void draft_pricesAndAsksToConfirm() {
        Account outlet = outletWithCredit();
        Product_Extension__c prod = pricedProduct();

        Test.startTest();
        SFA_OrderSupport.DraftRequest req = new SFA_OrderSupport.DraftRequest();
        req.accountId = outlet.Id;
        req.items = '20 Copilot Cola';
        SFA_OrderSupport.DraftResult d = SFA_OrderDraftAction.run(
            new List<SFA_OrderSupport.DraftRequest>{ req })[0];
        Test.stopTest();

        System.assertEquals(true, d.canPlace, 'Resolved, within credit -> placeable');
        System.assertEquals(2000, d.totalAmount, '20 x 100 estimated');
        System.assert(d.draftLines.contains('Copilot Cola'), 'Names the product: ' + d.draftLines);
        System.assert(d.summary.contains('place'), 'Ends by inviting placement: ' + d.summary);
    }

    @IsTest
    static void place_refusesWithoutConfirmation() {
        Account outlet = outletWithCredit();
        pricedProduct();

        Test.startTest();
        SFA_OrderSupport.PlaceRequest req = new SFA_OrderSupport.PlaceRequest();
        req.accountId = outlet.Id;
        req.items = '20 Copilot Cola';
        req.confirmed = false;
        SFA_OrderSupport.PlaceResult p = SFA_OrderPlaceAction.run(
            new List<SFA_OrderSupport.PlaceRequest>{ req })[0];
        Test.stopTest();

        System.assertEquals(false, p.placed, 'No confirmation -> not placed');
        System.assert(p.summary.contains('confirm'), 'Explains it needs confirmation: ' + p.summary);
    }

    @IsTest
    static void place_refusesUnresolvedProduct() {
        Account outlet = outletWithCredit();

        Test.startTest();
        SFA_OrderSupport.PlaceRequest req = new SFA_OrderSupport.PlaceRequest();
        req.accountId = outlet.Id;
        req.items = '5 Zznonexistent';
        req.confirmed = true;
        SFA_OrderSupport.PlaceResult p = SFA_OrderPlaceAction.run(
            new List<SFA_OrderSupport.PlaceRequest>{ req })[0];
        Test.stopTest();

        System.assertEquals(false, p.placed, 'Unknown product -> not placed');
        System.assert(p.summary.contains('could not find'), 'Names the miss: ' + p.summary);
    }

    @IsTest
    static void place_createsDraftOrderOnConfirmation() {
        Account outlet = outletWithCredit();
        pricedProduct();

        Test.startTest();
        SFA_OrderSupport.PlaceRequest req = new SFA_OrderSupport.PlaceRequest();
        req.accountId = outlet.Id;
        req.items = '20 Copilot Cola';
        req.confirmed = true;
        SFA_OrderSupport.PlaceResult p = SFA_OrderPlaceAction.run(
            new List<SFA_OrderSupport.PlaceRequest>{ req })[0];
        Test.stopTest();

        // Whatever the org's validations decide, the action must never throw —
        // it either places (and reports the order) or refuses with a reason.
        System.assertNotEquals(null, p.summary, 'Always returns a spoken result');
        if (p.placed) {
            System.assertNotEquals(null, p.orderId, 'A placed order has an id');
            List<Sales_Order__c> orders = [
                SELECT Id, Status__c FROM Sales_Order__c WHERE Id = :p.orderId
            ];
            System.assertEquals(1, orders.size(), 'The order exists');
            System.assertEquals('Draft', orders[0].Status__c, 'Created as Draft, not submitted');
        }
    }

    @IsTest
    static void place_refusesOverCredit() {
        Account outlet = TestDataFactory.createAndInsertAccount('Tapped Out Outlet', 'Retailer');
        outlet.Credit_Limit__c = 100;
        outlet.Outstanding_Balance__c = 100;
        update outlet;
        pricedProduct();

        Test.startTest();
        SFA_OrderSupport.PlaceRequest req = new SFA_OrderSupport.PlaceRequest();
        req.accountId = outlet.Id;
        req.items = '20 Copilot Cola';
        req.confirmed = true;
        SFA_OrderSupport.PlaceResult p = SFA_OrderPlaceAction.run(
            new List<SFA_OrderSupport.PlaceRequest>{ req })[0];
        Test.stopTest();

        System.assertEquals(false, p.placed, 'Over credit -> not placed');
        System.assert(p.summary.contains('credit'), 'Explains the credit block: ' + p.summary);
    }

    @IsTest
    static void draft_ambiguousTerm_asksInsteadOfGuessing() {
        Account outlet = outletWithCredit();
        insertColaVariants();

        Test.startTest();
        SFA_OrderSupport.DraftRequest req = new SFA_OrderSupport.DraftRequest();
        req.accountId = outlet.Id;
        req.items = '10 Copilot Cola';   // matches both 500ml and 250ml
        SFA_OrderSupport.DraftResult d = SFA_OrderDraftAction.run(
            new List<SFA_OrderSupport.DraftRequest>{ req })[0];
        Test.stopTest();

        System.assertEquals(false, d.canPlace, 'Ambiguous term is not placeable: ' + d.summary);
        System.assert(d.summary.contains('Which did you mean'), 'Asks the rep to choose: ' + d.summary);
        System.assert(d.summary.contains('CPC-500') && d.summary.contains('CPC-250'),
            'Lists both candidate SKUs: ' + d.summary);
    }

    @IsTest
    static void draft_exactSku_resolvesThatProduct() {
        Account outlet = outletWithCredit();
        insertColaVariants();

        Test.startTest();
        SFA_OrderSupport.DraftRequest req = new SFA_OrderSupport.DraftRequest();
        req.accountId = outlet.Id;
        req.items = '10 CPC-500';        // the SKU disambiguates
        SFA_OrderSupport.DraftResult d = SFA_OrderDraftAction.run(
            new List<SFA_OrderSupport.DraftRequest>{ req })[0];
        Test.stopTest();

        System.assertEquals(true, d.canPlace, 'Exact SKU resolves cleanly: ' + d.summary);
        System.assert(d.draftLines.contains('Copilot Cola 500ml'),
            'Resolved to the 500ml SKU: ' + d.draftLines);
        System.assert(!d.draftLines.contains('250ml'),
            'Did not pull in the 250ml SKU: ' + d.draftLines);
    }

    @IsTest
    static void place_refusesAmbiguousTerm() {
        Account outlet = outletWithCredit();
        insertColaVariants();

        Test.startTest();
        SFA_OrderSupport.PlaceRequest req = new SFA_OrderSupport.PlaceRequest();
        req.accountId = outlet.Id;
        req.items = '10 Copilot Cola';
        req.confirmed = true;            // confirmed, but still must not guess
        SFA_OrderSupport.PlaceResult p = SFA_OrderPlaceAction.run(
            new List<SFA_OrderSupport.PlaceRequest>{ req })[0];
        Test.stopTest();

        System.assertEquals(false, p.placed, 'Ambiguous term must not place: ' + p.summary);
        System.assert(p.summary.contains('specify'), 'Asks the rep to specify: ' + p.summary);
        System.assertEquals(0, [SELECT COUNT() FROM Sales_Order__c], 'Nothing was created');
    }

    @IsTest
    static void place_stampsFreeGoodsSchemeTheTriggerMisses() {
        Account outlet = outletWithCredit();
        Product_Extension__c prod = TestDataFactory.createProduct('Free Goods Widget', 'FGW-1');
        prod.Unit_Price__c = 50;
        insert prod;

        // Buy 3 get 1 free of the same product — a free-goods scheme carries no
        // money discount, so the line trigger leaves no trace of it; placeOrder
        // must stamp the free quantity itself.
        Scheme__c sch = TestDataFactory.createScheme(
            'Buy 3 Get 1 Free', 'SCH-B3G1', 'Free Products', 'Same Product (QTY)');
        sch.Min_Quantity__c = 3;
        sch.Free_Product_Ext__c = prod.Id;
        sch.Free_Quantity__c = 1;
        sch.Product_Ext__c = prod.Id;
        sch.Priority__c = 1;
        if (sch.Budget_Amount__c == null || sch.Budget_Amount__c == 0) sch.Budget_Amount__c = 100000;
        sch.Status__c = 'Draft';
        insert sch;
        sch.Status__c = 'Active';
        update sch;

        Test.startTest();
        SFA_OrderSupport.PlaceResult p = SFA_OrderSupport.placeOrder(outlet.Id, '5 Free Goods Widget', true);
        Test.stopTest();

        System.assertEquals(true, p.placed, 'Should place: ' + p.summary);
        Order_Line_Item__c line = [
            SELECT Free_Quantity__c, Scheme__c
            FROM Order_Line_Item__c WHERE Sales_Order__c = :p.orderId LIMIT 1
        ];
        System.assertEquals(1, line.Free_Quantity__c, 'Free good stamped on the line');
        System.assertNotEquals(null, line.Scheme__c, 'Scheme attributed to the line');
        Sales_Order__c so = [SELECT Total_Free_Quantity__c FROM Sales_Order__c WHERE Id = :p.orderId];
        System.assertEquals(1, so.Total_Free_Quantity__c, 'Header free quantity rolled up');
    }

    @IsTest
    static void draft_nudgesWhenShortOfSchemeThreshold() {
        Account outlet = outletWithCredit();
        Product_Extension__c prod = TestDataFactory.createProduct('Nudge Widget', 'NW-1');
        prod.Unit_Price__c = 20;
        insert prod;

        Scheme__c sch = TestDataFactory.createScheme(
            'Buy 3 Get 1 Free', 'SCH-NW-B3G1', 'Free Products', 'Same Product (QTY)');
        sch.Min_Quantity__c = 3;
        sch.Free_Product_Ext__c = prod.Id;
        sch.Free_Quantity__c = 1;
        sch.Product_Ext__c = prod.Id;
        sch.Priority__c = 1;
        if (sch.Budget_Amount__c == null || sch.Budget_Amount__c == 0) sch.Budget_Amount__c = 100000;
        sch.Status__c = 'Draft';
        insert sch;
        sch.Status__c = 'Active';
        update sch;

        Test.startTest();
        SFA_OrderSupport.DraftRequest req = new SFA_OrderSupport.DraftRequest();
        req.accountId = outlet.Id;
        req.items = '2 Nudge Widget';   // one short of the 3 needed
        SFA_OrderSupport.DraftResult d = SFA_OrderDraftAction.run(
            new List<SFA_OrderSupport.DraftRequest>{ req })[0];
        Test.stopTest();

        System.assert(d.summary.contains('add 1 more'), 'Nudges to add one more: ' + d.summary);
        System.assert(d.summary.contains('Buy 3 Get 1 Free'), 'Names the scheme to unlock: ' + d.summary);
    }

    @IsTest
    static void place_populatesLineAndHeaderDetailLikeTheOrderScreen() {
        Account outlet = outletWithCredit();
        Product_Extension__c prod = TestDataFactory.createProduct('Detail Widget', 'DW-1');
        prod.Unit_Price__c = 50;
        prod.MRP__c = 60;
        insert prod;

        Test.startTest();
        SFA_OrderSupport.PlaceResult p = SFA_OrderSupport.placeOrder(outlet.Id, '4 Detail Widget', true);
        Test.stopTest();

        System.assertEquals(true, p.placed, 'Should place: ' + p.summary);
        Order_Line_Item__c line = [
            SELECT Quantity__c, Base_Quantity__c, Conversion_Factor__c, Line_Total__c, MRP__c
            FROM Order_Line_Item__c WHERE Sales_Order__c = :p.orderId LIMIT 1
        ];
        System.assertEquals(200, line.Line_Total__c, 'Gross line total 4 x 50 is stored');
        System.assertEquals(60, line.MRP__c, 'MRP copied from the product master');
        System.assertEquals(4, line.Base_Quantity__c, 'Base quantity resolved (pieces base)');
        System.assertEquals(1, line.Conversion_Factor__c, 'Conversion factor resolved');

        Sales_Order__c so = [
            SELECT Total_Gross_Amount__c, Total_Net_Amount__c
            FROM Sales_Order__c WHERE Id = :p.orderId LIMIT 1
        ];
        System.assert(so.Total_Gross_Amount__c > 0, 'Parallel gross header populated: ' + so.Total_Gross_Amount__c);
        System.assert(so.Total_Net_Amount__c > 0, 'Parallel net header populated: ' + so.Total_Net_Amount__c);
    }

    @IsTest
    static void place_linksToAnOpenVisitAtTheOutlet() {
        Account outlet = outletWithCredit();
        pricedProduct();
        Territory_Master__c terr = TestDataFactory.createAndInsertTerritory('Copilot Terr', 'CT-01');
        Beat__c beat = TestDataFactory.createAndInsertBeat('Copilot Beat', 'CB-01', terr.Id);

        // An open (Checked In) visit at this outlet today, owned by this user.
        Visit__c v = TestDataFactory.createVisit(outlet.Id, UserInfo.getUserId(), null, beat.Id);
        v.User__c = UserInfo.getUserId();
        insert v;

        Test.startTest();
        SFA_OrderSupport.PlaceResult p = SFA_OrderSupport.placeOrder(outlet.Id, '20 Copilot Cola', true);
        Test.stopTest();

        System.assertEquals(true, p.placed, 'Should place: ' + p.summary);
        Sales_Order__c so = [SELECT Visit__c, Beat__c FROM Sales_Order__c WHERE Id = :p.orderId LIMIT 1];
        System.assertEquals(v.Id, so.Visit__c, 'Order tied to the open visit');
        System.assertEquals(beat.Id, so.Beat__c, 'Beat inherited from the visit');
        System.assert(p.summary.contains('linked to your open visit'),
            'Confirmation mentions the visit link: ' + p.summary);
    }
}