/**
 * @description Covers the credit-exceeded order approval flow: a flagged order
 *              must NOT auto-approve (the OMS_SalesOrder_AutoApproval flow is
 *              gated on Requires_Credit_Approval__c), it routes through
 *              ApprovalRouter to the configured approver, and approving the
 *              request writes Approved back onto the order.
 *
 *              The rule here routes to the running user (kept as both submitter
 *              and approver) so the test needs no second user; Manager-type
 *              approver resolution is covered by the engine's own tests.
 */
@IsTest
private class OrderCreditApproval_Test {

    private static Approval_Rule__c makeCreditRule() {
        Approval_Rule__c rule = new Approval_Rule__c(
            Name = 'Test SO Credit Approval',
            Object_Process__c = 'Sales_Order__c',
            Is_Active__c = true,
            Approval_Level__c = 1,
            Approval_Mode__c = 'Sequential',
            Approver_Type__c = 'User',
            User__c = UserInfo.getUserId(),
            Criteria_Logic__c = 'AND',
            Status_Field_API_Name__c = 'Status__c',
            Status_Value_On_Submit__c = 'Submitted',
            Status_Value_On_Approve__c = 'Approved',
            Status_Value_On_Reject__c = 'Rejected',
            Effective_From__c = Date.today().addMonths(-1),
            Effective_To__c = Date.today().addYears(5)
        );
        insert rule;
        insert new Approval_Rule_Condition__c(
            Approval_Rule__c = rule.Id,
            Field_API_Name__c = 'Requires_Credit_Approval__c',
            Operator__c = 'equals',
            Value__c = 'true',
            Sequence__c = 1
        );
        return rule;
    }

    @IsTest
    static void creditFlaggedOrder_isGatedRoutedAndApproved() {
        makeCreditRule();
        Account outlet = TestDataFactory.createAndInsertAccount('Credit Approval Outlet', 'Retailer');
        Territory_Master__c terr = TestDataFactory.createAndInsertTerritory('Credit Terr', 'CT-CR1');

        Test.startTest();
        // A flagged, sub-threshold order: value alone (20k <= 50k) would
        // auto-approve, so if it stays Submitted the flag gate is working.
        Sales_Order__c so = new Sales_Order__c(
            Account__c = outlet.Id,
            Status__c = 'Submitted',
            Order_Date__c = Date.today(),
            Territory__c = terr.Id,
            Requires_Credit_Approval__c = true,
            Total_Net_Amount__c = 20000
        );
        insert so;
        Test.stopTest();

        System.assertEquals('Submitted',
            [SELECT Status__c FROM Sales_Order__c WHERE Id = :so.Id].Status__c,
            'A credit-flagged order must not auto-approve');

        Id reqId = ApprovalRouter.submit(so.Id, 'Order value exceeds the outlet credit limit.');
        List<Approval_Step__c> steps = [
            SELECT Id, Approver__c, Status__c
            FROM Approval_Step__c WHERE Approval_Request__c = :reqId
        ];
        System.assertEquals(1, steps.size(), 'One approval step is created');
        System.assertEquals(UserInfo.getUserId(), steps[0].Approver__c,
            'The step is routed to the configured approver');
        System.assertEquals('Submitted',
            [SELECT Status__c FROM Sales_Order__c WHERE Id = :so.Id].Status__c,
            'The order stays pending until the approver decides');

        ApprovalRouter.approve(steps[0].Id, 'Approved in test');

        System.assertEquals('Approved',
            [SELECT Status__c FROM Sales_Order__c WHERE Id = :so.Id].Status__c,
            'Approving the request writes Approved back onto the order');
    }

    @IsTest
    static void rejectedRequest_writesRejectedToOrder() {
        makeCreditRule();
        Account outlet = TestDataFactory.createAndInsertAccount('Credit Reject Outlet', 'Retailer');
        Territory_Master__c terr = TestDataFactory.createAndInsertTerritory('Credit Terr 2', 'CT-CR2');

        Sales_Order__c so = new Sales_Order__c(
            Account__c = outlet.Id, Status__c = 'Submitted', Order_Date__c = Date.today(),
            Territory__c = terr.Id, Requires_Credit_Approval__c = true, Total_Net_Amount__c = 20000
        );
        insert so;

        Test.startTest();
        Id reqId = ApprovalRouter.submit(so.Id, 'Order value exceeds the outlet credit limit.');
        Approval_Step__c step = [SELECT Id FROM Approval_Step__c WHERE Approval_Request__c = :reqId LIMIT 1];
        ApprovalRouter.reject(step.Id, 'Rejected in test');
        Test.stopTest();

        System.assertEquals('Rejected',
            [SELECT Status__c FROM Sales_Order__c WHERE Id = :so.Id].Status__c,
            'Rejecting the request writes Rejected back onto the order');
    }
}