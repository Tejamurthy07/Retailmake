/**
 * @description Controller for saved Dynamic KPI Dashboard views. Provides
 *              CRUD operations scoped to the current user with visibility
 *              rules:
 *                - Owners can edit/delete their own views
 *                - Shared views are visible to all users
 *                - Each user can mark one of their own views as default
 *
 * @author  SFA Development Team
 * @date    2026
 */
public with sharing class DKD_DashboardView_Controller {

    /**
     * @description Returns all dashboard views visible to the current user
     *              (own views + all shared views), ordered by default first
     *              then name.
     */
    @AuraEnabled
    public static List<Map<String, Object>> getMyViews() {
        Id uid = UserInfo.getUserId();
        List<Dashboard_View__c> views = [
            SELECT Id, Name, Description__c, Icon__c, Is_Shared__c, Is_Default__c,
                   Owner_User__c, Owner_User__r.Name, LastModifiedDate,
                   Configuration_JSON__c
            FROM Dashboard_View__c
            WHERE Owner_User__c = :uid OR Is_Shared__c = true
            ORDER BY Is_Default__c DESC, Name ASC
            LIMIT 500
        ];

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Dashboard_View__c v : views) {
            Map<String, Object> row = new Map<String, Object>();
            row.put('id', v.Id);
            row.put('name', v.Name);
            row.put('description', v.Description__c);
            row.put('icon', String.isNotBlank(v.Icon__c) ? v.Icon__c : 'utility:chart');
            row.put('isShared', v.Is_Shared__c);
            row.put('isDefault', v.Is_Default__c);
            row.put('ownerId', v.Owner_User__c);
            row.put('ownerName', v.Owner_User__r != null ? v.Owner_User__r.Name : '');
            row.put('isOwn', v.Owner_User__c == uid);
            row.put('lastModified', v.LastModifiedDate);
            row.put('configuration', v.Configuration_JSON__c);
            result.add(row);
        }
        return result;
    }

    /**
     * @description Returns the current user's default view (if set), or null.
     */
    @AuraEnabled
    public static Dashboard_View__c getDefaultView() {
        Id uid = UserInfo.getUserId();
        List<Dashboard_View__c> views = [
            SELECT Id, Name, Description__c, Icon__c, Is_Shared__c, Is_Default__c,
                   Owner_User__c, Configuration_JSON__c
            FROM Dashboard_View__c
            WHERE Owner_User__c = :uid AND Is_Default__c = true
            LIMIT 1
        ];
        return views.isEmpty() ? null : views[0];
    }

    /**
     * @description Creates a new dashboard view owned by the current user.
     */
    @AuraEnabled
    public static Dashboard_View__c createView(
        String name,
        String description,
        String configurationJson,
        Boolean isShared,
        String icon
    ) {
        if (String.isBlank(name)) {
            throw new AuraHandledException('Name is required.');
        }
        if (String.isBlank(configurationJson)) {
            throw new AuraHandledException('Configuration is required.');
        }

        Dashboard_View__c v = new Dashboard_View__c(
            Name = name.trim(),
            Description__c = description,
            Configuration_JSON__c = configurationJson,
            Is_Shared__c = isShared == true,
            Owner_User__c = UserInfo.getUserId(),
            Icon__c = String.isNotBlank(icon) ? icon : null
        );
        insert v;
        return v;
    }

    /**
     * @description Updates an existing dashboard view. Only the owner may update.
     */
    @AuraEnabled
    public static Dashboard_View__c updateView(
        Id viewId,
        String name,
        String description,
        String configurationJson,
        Boolean isShared,
        String icon
    ) {
        Dashboard_View__c existing = loadOwnView(viewId);

        if (String.isNotBlank(name)) existing.Name = name.trim();
        existing.Description__c = description;
        if (String.isNotBlank(configurationJson)) {
            existing.Configuration_JSON__c = configurationJson;
        }
        if (isShared != null) existing.Is_Shared__c = isShared;
        if (icon != null) existing.Icon__c = String.isBlank(icon) ? null : icon;

        update existing;
        return existing;
    }

    /**
     * @description Deletes a dashboard view. Only the owner may delete.
     */
    @AuraEnabled
    public static void deleteView(Id viewId) {
        Dashboard_View__c existing = loadOwnView(viewId);
        delete existing;
    }

    /**
     * @description Marks the given view as the current user's default,
     *              unsetting any previous default for the same user.
     *              The target view must be owned by the current user.
     */
    @AuraEnabled
    public static Dashboard_View__c setDefaultView(Id viewId) {
        Dashboard_View__c target = loadOwnView(viewId);

        // Clear any existing default for this user
        Id uid = UserInfo.getUserId();
        List<Dashboard_View__c> existingDefaults = [
            SELECT Id, Is_Default__c
            FROM Dashboard_View__c
            WHERE Owner_User__c = :uid AND Is_Default__c = true AND Id != :viewId
        ];
        if (!existingDefaults.isEmpty()) {
            for (Dashboard_View__c v : existingDefaults) {
                v.Is_Default__c = false;
            }
            update existingDefaults;
        }

        target.Is_Default__c = true;
        update target;
        return target;
    }

    /**
     * @description Removes the default flag from the user's current default view.
     */
    @AuraEnabled
    public static void clearDefaultView() {
        Id uid = UserInfo.getUserId();
        List<Dashboard_View__c> existing = [
            SELECT Id, Is_Default__c
            FROM Dashboard_View__c
            WHERE Owner_User__c = :uid AND Is_Default__c = true
        ];
        if (existing.isEmpty()) return;
        for (Dashboard_View__c v : existing) {
            v.Is_Default__c = false;
        }
        update existing;
    }

    /**
     * @description Duplicates an existing view (own or shared) into a new
     *              record owned by the current user.
     */
    @AuraEnabled
    public static Dashboard_View__c duplicateView(Id viewId, String newName) {
        List<Dashboard_View__c> views = [
            SELECT Id, Name, Description__c, Icon__c, Configuration_JSON__c
            FROM Dashboard_View__c
            WHERE Id = :viewId
              AND (Owner_User__c = :UserInfo.getUserId() OR Is_Shared__c = true)
            LIMIT 1
        ];
        if (views.isEmpty()) {
            throw new AuraHandledException('View not found or not accessible.');
        }
        Dashboard_View__c src = views[0];
        Dashboard_View__c copy = new Dashboard_View__c(
            Name = String.isNotBlank(newName) ? newName : (src.Name + ' (Copy)'),
            Description__c = src.Description__c,
            Configuration_JSON__c = src.Configuration_JSON__c,
            Icon__c = src.Icon__c,
            Is_Shared__c = false,
            Is_Default__c = false,
            Owner_User__c = UserInfo.getUserId()
        );
        insert copy;
        return copy;
    }

    // ── Private helpers ─────────────────────────────────────────────────────

    private static Dashboard_View__c loadOwnView(Id viewId) {
        if (viewId == null) {
            throw new AuraHandledException('View Id is required.');
        }
        List<Dashboard_View__c> views = [
            SELECT Id, Name, Description__c, Icon__c, Is_Shared__c, Is_Default__c,
                   Owner_User__c, Configuration_JSON__c
            FROM Dashboard_View__c
            WHERE Id = :viewId
            LIMIT 1
        ];
        if (views.isEmpty()) {
            throw new AuraHandledException('Dashboard view not found.');
        }
        Dashboard_View__c v = views[0];
        if (v.Owner_User__c != UserInfo.getUserId()) {
            throw new AuraHandledException('You can only modify views you own.');
        }
        return v;
    }
}