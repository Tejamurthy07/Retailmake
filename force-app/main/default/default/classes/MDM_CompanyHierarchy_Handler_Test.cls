/**
 * @description Test class for MDM_CompanyHierarchy_Handler.
 *              Validates unique hierarchy code enforcement, circular reference
 *              detection, and territory rollup updates.
 * @author  SFA Development Team
 * @date    2024
 */
@IsTest
private class MDM_CompanyHierarchy_Handler_Test {

    @TestSetup
    static void setupTestData() {
        // Create a root hierarchy node
        Company_Hierarchy__c root = new Company_Hierarchy__c(
            Name = 'Root Company',
            Hierarchy_Code__c = 'ROOT-001',
            Is_Active__c = true
        );
        insert root;

        // Create a mid-level node under root
        Company_Hierarchy__c mid = new Company_Hierarchy__c(
            Name = 'Mid Level',
            Hierarchy_Code__c = 'MID-001',
            Parent_Hierarchy__c = root.Id,
            Is_Active__c = true
        );
        insert mid;
    }

    // ── Helper accessors ─────────────────────────────────────────────────────

    private static Company_Hierarchy__c getRoot() {
        return [SELECT Id, Total_Child_Nodes__c, Active_Child_Nodes__c
                FROM Company_Hierarchy__c WHERE Hierarchy_Code__c = 'ROOT-001' LIMIT 1];
    }
    private static Company_Hierarchy__c getMid() {
        return [SELECT Id FROM Company_Hierarchy__c WHERE Hierarchy_Code__c = 'MID-001' LIMIT 1];
    }

    // ── Unique code: successful insert with unique code ─────────────────────

    @IsTest
    static void testInsertUniqueCode() {
        Test.startTest();
        Company_Hierarchy__c node = new Company_Hierarchy__c(
            Name = 'Unique Node',
            Hierarchy_Code__c = 'UNIQ-001',
            Is_Active__c = true
        );
        insert node;
        Test.stopTest();

        System.assertNotEquals(null, node.Id, 'Node with unique code should be inserted');
    }

    // ── Unique code: duplicate code insert fails ────────────────────────────

    @IsTest
    static void testInsertDuplicateCodeFails() {
        Test.startTest();
        try {
            Company_Hierarchy__c dup = new Company_Hierarchy__c(
                Name = 'Duplicate Node',
                Hierarchy_Code__c = 'ROOT-001',
                Is_Active__c = true
            );
            insert dup;
            System.assert(false, 'Expected DmlException for duplicate hierarchy code');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('already exists'),
                'Error should mention code already exists: ' + e.getMessage());
        }
        Test.stopTest();
    }

    // ── Unique code: duplicate within same batch ────────────────────────────

    @IsTest
    static void testInsertDuplicateCodeInBatch() {
        Test.startTest();
        try {
            List<Company_Hierarchy__c> batch = new List<Company_Hierarchy__c>{
                new Company_Hierarchy__c(Name = 'Batch A', Hierarchy_Code__c = 'BATCH-DUP', Is_Active__c = true),
                new Company_Hierarchy__c(Name = 'Batch B', Hierarchy_Code__c = 'BATCH-DUP', Is_Active__c = true)
            };
            insert batch;
            System.assert(false, 'Expected DmlException for intra-batch duplicate codes');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('Duplicate Hierarchy Code'),
                'Error should mention duplicate within batch: ' + e.getMessage());
        }
        Test.stopTest();
    }

    // ── Unique code: update code to existing value fails ────────────────────

    @IsTest
    static void testUpdateCodeToDuplicateFails() {
        Company_Hierarchy__c mid = getMid();

        Test.startTest();
        try {
            mid.Hierarchy_Code__c = 'ROOT-001';
            update mid;
            System.assert(false, 'Expected DmlException for updating code to duplicate');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('already exists'),
                'Error should mention code already exists');
        }
        Test.stopTest();
    }

    // ── Circular hierarchy: self-reference blocked ──────────────────────────

    @IsTest
    static void testCircularSelfReference() {
        Company_Hierarchy__c root = getRoot();

        Test.startTest();
        try {
            root.Parent_Hierarchy__c = root.Id;
            update root;
            System.assert(false, 'Expected DmlException for self-referencing hierarchy');
        } catch (DmlException e) {
            String msg = e.getMessage();
            System.assert(
                msg.contains('Circular hierarchy detected') ||
                msg.contains('CIRCULAR_DEPENDENCY') ||
                msg.contains('Hierarchy Constraint Violation'),
                'Error should mention circular hierarchy (handler or platform check): ' + msg
            );
        }
        Test.stopTest();
    }

    // ── Circular hierarchy: indirect cycle blocked ──────────────────────────

    @IsTest
    static void testCircularIndirectCycle() {
        Company_Hierarchy__c root = getRoot();
        Company_Hierarchy__c mid = getMid();

        // Create a child under mid
        Company_Hierarchy__c child = new Company_Hierarchy__c(
            Name = 'Child Node',
            Hierarchy_Code__c = 'CHILD-001',
            Parent_Hierarchy__c = mid.Id,
            Is_Active__c = true
        );
        insert child;

        Test.startTest();
        try {
            // Try to make root a child of child (root -> mid -> child -> root = cycle)
            root.Parent_Hierarchy__c = child.Id;
            update root;
            System.assert(false, 'Expected DmlException for indirect circular hierarchy');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('Circular hierarchy detected'),
                'Error should mention circular hierarchy: ' + e.getMessage());
        }
        Test.stopTest();
    }

    // ── Valid parent assignment (no cycle) ───────────────────────────────────

    @IsTest
    static void testValidParentAssignment() {
        Company_Hierarchy__c root = getRoot();

        Company_Hierarchy__c newNode = new Company_Hierarchy__c(
            Name = 'New Sibling',
            Hierarchy_Code__c = 'SIB-001',
            Is_Active__c = true
        );
        insert newNode;

        Test.startTest();
        newNode.Parent_Hierarchy__c = root.Id;
        update newNode;
        Test.stopTest();

        Company_Hierarchy__c updated = [SELECT Parent_Hierarchy__c FROM Company_Hierarchy__c WHERE Id = :newNode.Id];
        System.assertEquals(root.Id, updated.Parent_Hierarchy__c, 'Parent assignment should succeed');
    }

    // ── Territory rollup: after insert updates parent counts ────────────────

    @IsTest
    static void testTerritoryRollupOnInsert() {
        Company_Hierarchy__c root = getRoot();

        Test.startTest();
        List<Company_Hierarchy__c> children = new List<Company_Hierarchy__c>();
        for (Integer i = 0; i < 3; i++) {
            children.add(new Company_Hierarchy__c(
                Name = 'Rollup Child ' + i,
                Hierarchy_Code__c = 'RC-' + String.valueOf(i).leftPad(3, '0'),
                Parent_Hierarchy__c = root.Id,
                Is_Active__c = true
            ));
        }
        insert children;
        Test.stopTest();

        Company_Hierarchy__c updatedRoot = [
            SELECT Total_Child_Nodes__c, Active_Child_Nodes__c
            FROM Company_Hierarchy__c WHERE Id = :root.Id
        ];
        // Root already had MID-001 as child, so total = 4 (1 existing + 3 new)
        System.assertEquals(4, updatedRoot.Total_Child_Nodes__c,
            'Total child count should be 4 (1 original + 3 new)');
        System.assertEquals(4, updatedRoot.Active_Child_Nodes__c,
            'Active child count should be 4 (all active)');
    }

    // ── Territory rollup: after update refreshes counts on deactivation ─────

    @IsTest
    static void testTerritoryRollupOnDeactivation() {
        Company_Hierarchy__c root = getRoot();
        Company_Hierarchy__c mid = getMid();

        Test.startTest();
        mid.Is_Active__c = false;
        update mid;
        Test.stopTest();

        Company_Hierarchy__c updatedRoot = [
            SELECT Total_Child_Nodes__c, Active_Child_Nodes__c
            FROM Company_Hierarchy__c WHERE Id = :root.Id
        ];
        System.assertEquals(1, updatedRoot.Total_Child_Nodes__c,
            'Total child count should remain 1');
        System.assertEquals(0, updatedRoot.Active_Child_Nodes__c,
            'Active child count should be 0 after deactivation');
    }

    // ── Territory rollup: parent change updates both old and new parent ─────

    @IsTest
    static void testRollupOnParentChange() {
        Company_Hierarchy__c root = getRoot();

        // Create a second root
        Company_Hierarchy__c root2 = new Company_Hierarchy__c(
            Name = 'Root Two',
            Hierarchy_Code__c = 'ROOT-002',
            Is_Active__c = true
        );
        insert root2;

        Company_Hierarchy__c mid = getMid();

        Test.startTest();
        mid.Parent_Hierarchy__c = root2.Id;
        update mid;
        Test.stopTest();

        Company_Hierarchy__c updatedRoot2 = [
            SELECT Total_Child_Nodes__c FROM Company_Hierarchy__c WHERE Id = :root2.Id
        ];
        System.assertEquals(1, updatedRoot2.Total_Child_Nodes__c,
            'New parent should have 1 child after reassignment');
    }

    // ── Insert without parent (no rollup triggered) ─────────────────────────

    @IsTest
    static void testInsertWithoutParent() {
        Test.startTest();
        Company_Hierarchy__c orphan = new Company_Hierarchy__c(
            Name = 'Orphan Node',
            Hierarchy_Code__c = 'ORPH-001',
            Is_Active__c = true
        );
        insert orphan;
        Test.stopTest();

        System.assertNotEquals(null, orphan.Id, 'Orphan node should be inserted successfully');
    }
}