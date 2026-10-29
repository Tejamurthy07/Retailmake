/**
 * @description Abstract base class for all trigger handlers in the SFA application.
 *              Provides a standardized framework for trigger execution with recursion
 *              prevention, bypass capabilities, and context-aware dispatch.
 *
 * Usage:
 *   public class MyObjectHandler extends TriggerHandler {
 *       override void beforeInsert() { // logic }
 *   }
 *
 *   trigger MyObjectTrigger on MyObject__c (...) {
 *       new MyObjectHandler().run();
 *   }
 *
 * @author  SFA Development Team
 * @date    2024
 */
public abstract class TriggerHandler {

    // ── Static recursion & bypass management ──────────────────────────────────

    /** Tracks the number of times each handler has executed per context to prevent recursion. */
    @TestVisible
    private static Map<String, Integer> executionCountMap = new Map<String, Integer>();

    /** Maximum allowed executions per handler per transaction (configurable per handler). */
    @TestVisible
    private static Map<String, Integer> maxExecutionMap = new Map<String, Integer>();

    /** Set of handler class names that are currently bypassed. */
    @TestVisible
    private static Set<String> bypassedHandlers = new Set<String>();

    // ── Instance variables ────────────────────────────────────────────────────

    /** The resolved handler class name used for recursion and bypass tracking. */
    private String handlerName;

    /** The current trigger context provided by the runtime. */
    @TestVisible
    private System.TriggerOperation triggerContext;

    // ── Constructor ───────────────────────────────────────────────────────────

    /**
     * @description Default constructor. Resolves the concrete handler name via
     *              runtime type introspection and sets the trigger context.
     */
    public TriggerHandler() {
        this.handlerName = String.valueOf(this).split(':')[0];
        this.setTriggerContext();
    }

    // ── Public entry point ────────────────────────────────────────────────────

    /**
     * @description Main entry point invoked from the trigger body. Validates the
     *              execution context, checks for bypass/recursion, and dispatches
     *              to the appropriate virtual method.
     * @throws TriggerHandlerException when invoked outside of a trigger context.
     */
    public void run() {
        if (this.triggerContext == null) {
            throw new TriggerHandlerException(
                'TriggerHandler.run() was called outside of a trigger context. ' +
                'Handler: ' + this.handlerName
            );
        }

        if (isBypassed(this.handlerName)) {
            return;
        }

        if (hasExceededMaxExecutions()) {
            return;
        }

        incrementExecutionCount();

        switch on this.triggerContext {
            when BEFORE_INSERT  { this.beforeInsert(); }
            when BEFORE_UPDATE  { this.beforeUpdate(); }
            when BEFORE_DELETE  { this.beforeDelete(); }
            when AFTER_INSERT   { this.afterInsert();  }
            when AFTER_UPDATE   { this.afterUpdate();  }
            when AFTER_DELETE   { this.afterDelete();   }
            when AFTER_UNDELETE { this.afterUndelete(); }
        }

        this.dispatchConfiguredNotifications();
    }

    /**
     * @description Raises the configured notification events for this object
     *              after the handler's own logic has run.
     *
     *              Wiring this centrally rather than per-handler is deliberate:
     *              it means adding notifications to an object is purely a
     *              Notification_Setting__c record, never a code change, and no
     *              object can be forgotten. NotificationTriggerHelper
     *              short-circuits on a cached lookup when nothing is configured
     *              for the object, so the cost here is negligible.
     *
     *              Failures are swallowed by design — a notification problem
     *              must never roll back the business transaction that caused it.
     */
    private void dispatchConfiguredNotifications() {
        if (this.triggerContext != System.TriggerOperation.AFTER_INSERT
            && this.triggerContext != System.TriggerOperation.AFTER_UPDATE) {
            return;
        }
        if (Trigger.new == null || Trigger.new.isEmpty()) {
            return;
        }
        try {
            String objectApiName = Trigger.new[0].getSObjectType().getDescribe().getName();
            if (this.triggerContext == System.TriggerOperation.AFTER_INSERT) {
                NotificationTriggerHelper.handleInsert(objectApiName, Trigger.new);
            } else {
                NotificationTriggerHelper.handleUpdate(objectApiName, Trigger.new, Trigger.oldMap);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'Configured notification dispatch failed: ' + e.getMessage());
        }
    }

    // ── Virtual methods for subclass override ─────────────────────────────────

    /** @description Override to handle before-insert logic. */
    protected virtual void beforeInsert() {}

    /** @description Override to handle before-update logic. */
    protected virtual void beforeUpdate() {}

    /** @description Override to handle before-delete logic. */
    protected virtual void beforeDelete() {}

    /** @description Override to handle after-insert logic. */
    protected virtual void afterInsert() {}

    /** @description Override to handle after-update logic. */
    protected virtual void afterUpdate() {}

    /** @description Override to handle after-delete logic. */
    protected virtual void afterDelete() {}

    /** @description Override to handle after-undelete logic. */
    protected virtual void afterUndelete() {}

    // ── Bypass management (static) ────────────────────────────────────────────

    /**
     * @description Prevents the specified handler from executing for the
     *              remainder of the transaction.
     * @param handlerName The Apex class name of the handler to bypass.
     */
    public static void bypass(String handlerName) {
        bypassedHandlers.add(handlerName);
    }

    /**
     * @description Removes bypass for the specified handler, allowing it to
     *              execute again.
     * @param handlerName The Apex class name of the handler to re-enable.
     */
    public static void clearBypass(String handlerName) {
        bypassedHandlers.remove(handlerName);
    }

    /**
     * @description Checks whether the specified handler is currently bypassed.
     * @param handlerName The Apex class name to check.
     * @return True if the handler is bypassed.
     */
    public static Boolean isBypassed(String handlerName) {
        return bypassedHandlers.contains(handlerName);
    }

    /**
     * @description Removes all handler bypasses. Useful for test setup/teardown.
     */
    public static void clearAllBypasses() {
        bypassedHandlers.clear();
    }

    // ── Max-execution management ──────────────────────────────────────────────

    /**
     * @description Sets the maximum number of times a handler may execute per
     *              transaction. Defaults to unlimited when not set.
     * @param max The maximum execution count.
     */
    public void setMaxExecutions(Integer max) {
        maxExecutionMap.put(this.handlerName, max);
    }

    // ── Execution-count helpers ───────────────────────────────────────────────

    /**
     * @description Resets the execution count for the specified handler.
     * @param handlerName The handler class name.
     */
    public static void resetExecutionCount(String handlerName) {
        executionCountMap.remove(handlerName);
    }

    /**
     * @description Resets all handler execution counts.
     */
    public static void resetAllExecutionCounts() {
        executionCountMap.clear();
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    /**
     * @description Resolves the current trigger context from the runtime.
     */
    @TestVisible
    private void setTriggerContext() {
        if (Trigger.isExecuting) {
            this.triggerContext = Trigger.operationType;
        }
    }

    /**
     * @description Increments the execution count for this handler.
     */
    private void incrementExecutionCount() {
        Integer count = executionCountMap.containsKey(this.handlerName)
            ? executionCountMap.get(this.handlerName)
            : 0;
        executionCountMap.put(this.handlerName, count + 1);
    }

    /**
     * @description Checks whether this handler has already exceeded its
     *              configured maximum execution count.
     * @return True if the handler should be skipped.
     */
    private Boolean hasExceededMaxExecutions() {
        if (!maxExecutionMap.containsKey(this.handlerName)) {
            return false;
        }
        Integer max = maxExecutionMap.get(this.handlerName);
        Integer current = executionCountMap.containsKey(this.handlerName)
            ? executionCountMap.get(this.handlerName)
            : 0;
        return current >= max;
    }
}