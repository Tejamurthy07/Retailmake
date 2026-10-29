@isTest
private class TriggerHandler_Test {

    // Concrete subclass we can instantiate from a test context to exercise
    // the framework without going through a real trigger.
    @TestVisible
    private class TestHandler extends TriggerHandler {
        public Integer beforeInsertCalls = 0;
        public Integer beforeUpdateCalls = 0;
        public Integer beforeDeleteCalls = 0;
        public Integer afterInsertCalls = 0;
        public Integer afterUpdateCalls = 0;
        public Integer afterDeleteCalls = 0;
        public Integer afterUndeleteCalls = 0;

        protected override void beforeInsert()  { beforeInsertCalls++; }
        protected override void beforeUpdate()  { beforeUpdateCalls++; }
        protected override void beforeDelete()  { beforeDeleteCalls++; }
        protected override void afterInsert()   { afterInsertCalls++; }
        protected override void afterUpdate()   { afterUpdateCalls++; }
        protected override void afterDelete()   { afterDeleteCalls++; }
        protected override void afterUndelete() { afterUndeleteCalls++; }
    }

    @isTest
    static void testRun_OutsideTriggerContext_Throws() {
        TestHandler h = new TestHandler();

        Test.startTest();
        Boolean threw = false;
        try {
            h.run();
        } catch (TriggerHandlerException e) {
            threw = true;
            System.assert(e.getMessage().contains('outside of a trigger context'),
                'Error msg: ' + e.getMessage());
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'Calling run outside trigger should throw');
    }

    /**
     * @description Same derivation used by the TriggerHandler constructor.
     */
    private static String handlerNameFor(TriggerHandler h) {
        return String.valueOf(h).split(':')[0];
    }

    @isTest
    static void testRun_BypassedHandler_NoOp() {
        TestHandler h = new TestHandler();
        h.triggerContext = System.TriggerOperation.BEFORE_INSERT;

        String handlerName = handlerNameFor(h);
        TriggerHandler.bypass(handlerName);
        System.assertEquals(true, TriggerHandler.isBypassed(handlerName));

        Test.startTest();
        h.run();
        Test.stopTest();

        System.assertEquals(0, h.beforeInsertCalls,
            'Bypassed handler should not have invoked beforeInsert (resolved name: '
            + handlerName + ')');

        TriggerHandler.clearBypass(handlerName);
        System.assertEquals(false, TriggerHandler.isBypassed(handlerName));
    }

    @isTest
    static void testRun_MaxExecutions_Skips() {
        TestHandler h = new TestHandler();
        h.triggerContext = System.TriggerOperation.BEFORE_INSERT;

        h.setMaxExecutions(1);

        Test.startTest();
        h.run();
        h.run();
        h.run();
        Test.stopTest();

        System.assertEquals(1, h.beforeInsertCalls,
            'Subsequent runs past the max should be skipped');
    }

    @isTest
    static void testDispatch_AllSevenContexts() {
        TestHandler h = new TestHandler();

        Map<System.TriggerOperation, String> contexts = new Map<System.TriggerOperation, String>{
            System.TriggerOperation.BEFORE_INSERT   => 'beforeInsert',
            System.TriggerOperation.BEFORE_UPDATE   => 'beforeUpdate',
            System.TriggerOperation.BEFORE_DELETE   => 'beforeDelete',
            System.TriggerOperation.AFTER_INSERT    => 'afterInsert',
            System.TriggerOperation.AFTER_UPDATE    => 'afterUpdate',
            System.TriggerOperation.AFTER_DELETE    => 'afterDelete',
            System.TriggerOperation.AFTER_UNDELETE  => 'afterUndelete'
        };

        Test.startTest();
        for (System.TriggerOperation op : contexts.keySet()) {
            h.triggerContext = op;
            h.run();
        }
        Test.stopTest();

        System.assertEquals(1, h.beforeInsertCalls);
        System.assertEquals(1, h.beforeUpdateCalls);
        System.assertEquals(1, h.beforeDeleteCalls);
        System.assertEquals(1, h.afterInsertCalls);
        System.assertEquals(1, h.afterUpdateCalls);
        System.assertEquals(1, h.afterDeleteCalls);
        System.assertEquals(1, h.afterUndeleteCalls);
    }

    @isTest
    static void testBypassLifecycle() {
        String name = handlerNameFor(new TestHandler());

        Test.startTest();
        TriggerHandler.bypass(name);
        System.assertEquals(true, TriggerHandler.isBypassed(name));

        TriggerHandler.clearBypass(name);
        System.assertEquals(false, TriggerHandler.isBypassed(name));

        TriggerHandler.bypass(name);
        TriggerHandler.bypass('Other');
        TriggerHandler.clearAllBypasses();
        System.assertEquals(false, TriggerHandler.isBypassed(name));
        System.assertEquals(false, TriggerHandler.isBypassed('Other'));
        Test.stopTest();
    }

    @isTest
    static void testExecutionCountReset() {
        TestHandler h = new TestHandler();
        h.triggerContext = System.TriggerOperation.AFTER_INSERT;

        String name = handlerNameFor(h);
        Test.startTest();
        h.run();
        h.run();
        TriggerHandler.resetExecutionCount(name);
        h.run();
        TriggerHandler.resetAllExecutionCounts();
        h.run();
        Test.stopTest();

        System.assertEquals(4, h.afterInsertCalls,
            'All 4 runs should have invoked afterInsert (no max set)');
    }

    @isTest
    static void testSetTriggerContext_NoOpOutsideTrigger() {
        // Default constructor calls setTriggerContext which is a no-op when
        // Trigger.isExecuting is false - just ensures the path is covered.
        Test.startTest();
        TestHandler h = new TestHandler();
        Test.stopTest();
        // Outside a trigger, the context stays null.
        System.assertEquals(null, h.triggerContext);
    }
}