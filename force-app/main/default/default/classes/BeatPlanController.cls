/**
 * @description Controller for the Beat Plan / Journey Plan LWC component.
 *              Manages monthly journey plans, beat assignments, approval workflows,
 *              and plan compliance tracking for FMCG field sales territory management.
 */
public with sharing class BeatPlanController {

    /**
     * @description Returns true if the running user has the 'Modify All Data'
     *              permission, used as an admin-override signal in the journey
     *              plan UI so admins can regenerate approved plans while regular
     *              users remain locked to the Draft/Rejected status gate.
     */
    @AuraEnabled(cacheable=true)
    public static Boolean isCurrentUserAdmin() {
        try {
            List<User> runningUser = [
                SELECT Id, Profile.PermissionsModifyAllData
                FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1
            ];
            if (runningUser.isEmpty() || runningUser[0].Profile == null) {
                return false;
            }
            return runningUser[0].Profile.PermissionsModifyAllData == true;
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * Wrapper class so the LWC receives a structured response with both the
     * plan header and the flattened list of day entries.
     */
    public class JourneyPlanResult {
        @AuraEnabled public Journey_Plan__c journeyPlan;
        @AuraEnabled public List<Journey_Plan_Day__c> planDays;
    }

    // ── Get Journey Plan by Record Id (for record-page context) ───────────────

    /**
     * @description Loads a Journey Plan directly by its record Id and returns
     *              a structured wrapper with the plan + day entries.
     * @param journeyPlanId The Journey_Plan__c record Id from the record page.
     * @return JourneyPlanResult wrapper.
     */
    @AuraEnabled
    public static JourneyPlanResult getJourneyPlanById(Id journeyPlanId) {
        List<Journey_Plan__c> plans = [
            SELECT Id, Name, Month__c, Year__c, Status__c, Salesperson__c,
                   Salesperson__r.Name, Total_Planned_Visits__c,
                   Territory__c, Territory__r.Name,
                   Effective_From__c, Effective_To__c,
                   Exclude_Holidays__c, Exclude_Leaves__c, Exclude_Week_Offs__c,
                   Approval_Date__c, Approved_By__c, Approved_By__r.Name
            FROM Journey_Plan__c
            WHERE Id = :journeyPlanId
            LIMIT 1
        ];

        JourneyPlanResult result = new JourneyPlanResult();
        if (plans.isEmpty()) {
            result.journeyPlan = null;
            result.planDays = new List<Journey_Plan_Day__c>();
            return result;
        }

        result.journeyPlan = plans[0];
        result.planDays = [
            SELECT Id, Day_of_Week__c, Week_Number__c, Beat__c,
                   Beat__r.Name, Beat__r.Beat_Code__c, Beat__r.Total_Outlets__c,
                   Planned_Outlets__c, Sequence_Order__c, Notes__c,
                   Plan_Date__c, Journey_Plan__c
            FROM Journey_Plan_Day__c
            WHERE Journey_Plan__c = :journeyPlanId
            ORDER BY Plan_Date__c, Sequence_Order__c
        ];
        return result;
    }

    // ── Get Journey Plan by User / Month / Year ───────────────────────────────

    /**
     * @description Retrieves a Journey Plan for a specific user, month and year.
     * @param userId The Salesperson (User) Id.
     * @param month  The month name (e.g. 'January', 'March').
     * @param year   The four-digit year string (e.g. '2026').
     * @return JourneyPlanResult wrapper, or empty wrapper if no plan exists.
     */
    @AuraEnabled
    public static JourneyPlanResult getJourneyPlan(Id userId, String month, String year) {
        // Calculate first/last day of the viewed month for date-range overlap matching
        Map<String, Integer> monthMap = new Map<String, Integer>{
            'January' => 1, 'February' => 2, 'March' => 3,
            'April' => 4, 'May' => 5, 'June' => 6,
            'July' => 7, 'August' => 8, 'September' => 9,
            'October' => 10, 'November' => 11, 'December' => 12
        };
        Integer monthInt = monthMap.containsKey(month) ? monthMap.get(month) : 1;
        Integer yearInt = Integer.valueOf(year);
        Date firstDayOfMonth = Date.newInstance(yearInt, monthInt, 1);
        Date lastDayOfMonth = Date.newInstance(yearInt, monthInt, Date.daysInMonth(yearInt, monthInt));

        // Find plans matching by exact month/year OR by date-range overlap
        List<Journey_Plan__c> plans = [
            SELECT Id, Name, Month__c, Year__c, Status__c, Salesperson__c,
                   Salesperson__r.Name, Total_Planned_Visits__c,
                   Territory__c, Territory__r.Name,
                   Effective_From__c, Effective_To__c,
                   Exclude_Holidays__c, Exclude_Leaves__c, Exclude_Week_Offs__c,
                   Approval_Date__c, Approved_By__c, Approved_By__r.Name
            FROM Journey_Plan__c
            WHERE Salesperson__c = :userId
            AND Status__c != 'Cancelled'
            AND (
                (Month__c = :month AND Year__c = :year)
                OR (Effective_From__c <= :lastDayOfMonth AND Effective_To__c >= :firstDayOfMonth)
            )
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        JourneyPlanResult result = new JourneyPlanResult();
        if (plans.isEmpty()) {
            result.journeyPlan = null;
            result.planDays = new List<Journey_Plan_Day__c>();
            return result;
        }

        result.journeyPlan = plans[0];
        result.planDays = [
            SELECT Id, Day_of_Week__c, Week_Number__c, Beat__c,
                   Beat__r.Name, Beat__r.Beat_Code__c, Beat__r.Total_Outlets__c,
                   Planned_Outlets__c, Sequence_Order__c, Notes__c,
                   Plan_Date__c, Journey_Plan__c
            FROM Journey_Plan_Day__c
            WHERE Journey_Plan__c = :plans[0].Id
            ORDER BY Plan_Date__c, Sequence_Order__c
        ];
        return result;
    }

    /**
     * @description Retrieves all active beats for a salesperson by looking up
     *              their assigned territory from Journey Plans or Territory assignments.
     * @param userId The User (Salesperson) Id.
     * @return List of Beat__c records from the user's territory.
     */
    @AuraEnabled
    public static List<Beat__c> getBeatsForUser(Id userId) {
        // First try to find territory from user's most recent Journey Plan
        List<Journey_Plan__c> plans = [
            SELECT Id, Salesperson__c
            FROM Journey_Plan__c
            WHERE Salesperson__c = :userId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        // Collect territory Ids from beats already linked to this user's plans
        Set<Id> territoryIds = new Set<Id>();

        // Look for beats assigned in any Journey Plan Day for this user
        List<Journey_Plan_Day__c> planDays = [
            SELECT Beat__r.Territory__c
            FROM Journey_Plan_Day__c
            WHERE Journey_Plan__r.Salesperson__c = :userId
            AND Beat__r.Territory__c != null
        ];
        for (Journey_Plan_Day__c pd : planDays) {
            territoryIds.add(pd.Beat__r.Territory__c);
        }

        // Also check if there are any Accounts assigned to this user with a territory
        if (territoryIds.isEmpty()) {
            List<Account> accts = [
                SELECT Territory__c
                FROM Account
                WHERE OwnerId = :userId
                AND Territory__c != null
                LIMIT 100
            ];
            for (Account a : accts) {
                territoryIds.add(a.Territory__c);
            }
        }

        if (territoryIds.isEmpty()) {
            // Return all active beats as fallback (admin/manager view)
            return [
                SELECT Id, Name, Beat_Code__c, Day_of_Week__c, Frequency__c,
                       Total_Outlets__c, Pincode_Cluster__c, Description__c,
                       Territory__c, Territory__r.Name, Assigned_User__c,
                       Is_Active__c, Sequence__c
                FROM Beat__c
                WHERE Is_Active__c = true
                ORDER BY Territory__r.Name, Beat_Code__c
                LIMIT 200
            ];
        }

        return [
            SELECT Id, Name, Beat_Code__c, Day_of_Week__c, Frequency__c,
                   Total_Outlets__c, Pincode_Cluster__c, Description__c,
                   Territory__c, Territory__r.Name, Assigned_User__c,
                   Is_Active__c, Sequence__c
            FROM Beat__c
            WHERE Territory__c IN :territoryIds
            AND Is_Active__c = true
            ORDER BY Beat_Code__c
        ];
    }

    /**
     * @description Retrieves beats assigned to a specific user (by Assigned_User__c).
     *              Used by the Executive picker to show a user's assigned beats.
     * @param userId The User Id to filter by Assigned_User__c.
     * @return List of Beat__c records assigned to the user.
     */
    @AuraEnabled
    public static List<Beat__c> getBeatsForExecutive(Id userId) {
        return [
            SELECT Id, Name, Beat_Code__c, Day_of_Week__c, Frequency__c,
                   Total_Outlets__c, Pincode_Cluster__c, Description__c,
                   Territory__c, Territory__r.Name, Assigned_User__c,
                   Is_Active__c, Sequence__c
            FROM Beat__c
            WHERE Assigned_User__c = :userId
            ORDER BY Territory__r.Name, Beat_Code__c
        ];
    }

    // ── Submit for Approval ───────────────────────────────────────────────────

    @AuraEnabled
    public static Journey_Plan__c submitForApproval(Id journeyPlanId) {
        try {
            Journey_Plan__c plan = [
                SELECT Id, Status__c, Salesperson__c
                FROM Journey_Plan__c
                WHERE Id = :journeyPlanId
                LIMIT 1
            ];

            if (plan.Status__c == 'Approved') {
                AuraHandledException ex = new AuraHandledException('This journey plan has already been approved.');
                ex.setMessage('This journey plan has already been approved.');
                throw ex;
            }
            if (plan.Status__c == 'Submitted') {
                AuraHandledException ex = new AuraHandledException('This journey plan has already been submitted for approval.');
                ex.setMessage('This journey plan has already been submitted for approval.');
                throw ex;
            }

            plan.Status__c = 'Submitted';
            update plan;

            Approval.ProcessSubmitRequest approvalReq = new Approval.ProcessSubmitRequest();
            approvalReq.setObjectId(journeyPlanId);
            approvalReq.setSubmitterId(UserInfo.getUserId());
            approvalReq.setComments('Journey Plan submitted for approval.');
            approvalReq.setSkipEntryCriteria(false);

            Approval.ProcessResult approvalResult = Approval.process(approvalReq);

            if (!approvalResult.isSuccess()) {
                plan.Status__c = 'Draft';
                update plan;
                String errorMsg = 'Approval submission failed.';
                if (approvalResult.getErrors() != null && !approvalResult.getErrors().isEmpty()) {
                    errorMsg = approvalResult.getErrors()[0].getMessage();
                }
                throw new AuraHandledException(errorMsg);
            }

            return [
                SELECT Id, Name, Status__c, Month__c, Year__c
                FROM Journey_Plan__c
                WHERE Id = :journeyPlanId
                LIMIT 1
            ];
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Beat CRUD ───────────────────────────────────────────────────────────

    @AuraEnabled
    public static Beat__c saveBeat(String beatJson) {
        // Received as JSON (not a typed SObject) so unqualified field keys survive
        // the hop — in the ftretailmake namespace an SObject param drops any value
        // whose key lacks the prefix. Rebuild server-side with real field names.
        if (String.isBlank(beatJson)) throw new AuraHandledException('Beat is required.');
        Beat__c beat = (Beat__c) buildSObject(
            Beat__c.SObjectType, (Map<String, Object>) JSON.deserializeUntyped(beatJson));
        return saveBeatInternal(beat);
    }

    public static Beat__c saveBeatInternal(Beat__c beat) {
        try {
            if (beat.Assigned_User__c != null) {
                beat.OwnerId = beat.Assigned_User__c;
            }
            upsert beat;
            return [
                SELECT Id, Name, Beat_Code__c, Day_of_Week__c, Frequency__c,
                       Total_Outlets__c, Pincode_Cluster__c, Description__c,
                       Territory__c, Territory__r.Name, Assigned_User__c,
                       Is_Active__c, Sequence__c
                FROM Beat__c
                WHERE Id = :beat.Id
            ];
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static Integer checkBeatDeactivationImpact(Id beatId) {
        return [
            SELECT COUNT() FROM Journey_Plan_Day__c
            WHERE Beat__c = :beatId AND Plan_Date__c >= TODAY
        ];
    }

    @AuraEnabled
    public static void deleteBeat(Id beatId) {
        try {
            delete [SELECT Id FROM Beat__c WHERE Id = :beatId];
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Beat Outlet Management ──────────────────────────────────────────────

    @AuraEnabled
    public static List<Beat_Outlet__c> getBeatOutlets(Id beatId) {
        return [
            SELECT Id, Beat__c, Account__c, Account__r.Name,
                   Is_Active__c, Visit_Sequence__c
            FROM Beat_Outlet__c
            WHERE Beat__c = :beatId
            ORDER BY Visit_Sequence__c
        ];
    }

    @AuraEnabled
    public static List<Beat_Outlet__c> addBeatOutlets(Id beatId, List<Id> accountIds) {
        try {
            Set<Id> existingAccountIds = new Set<Id>();
            for (Beat_Outlet__c bo : [SELECT Account__c FROM Beat_Outlet__c WHERE Beat__c = :beatId]) {
                existingAccountIds.add(bo.Account__c);
            }

            List<AggregateResult> maxSeqResult = [
                SELECT MAX(Visit_Sequence__c) maxVal
                FROM Beat_Outlet__c
                WHERE Beat__c = :beatId
            ];
            Integer nextSeq = 1;
            if (maxSeqResult[0].get('maxVal') != null) {
                nextSeq = ((Decimal)maxSeqResult[0].get('maxVal')).intValue() + 1;
            }

            List<Beat_Outlet__c> newOutlets = new List<Beat_Outlet__c>();
            for (Id accId : accountIds) {
                if (!existingAccountIds.contains(accId)) {
                    newOutlets.add(new Beat_Outlet__c(
                        Beat__c = beatId,
                        Account__c = accId,
                        Is_Active__c = true,
                        Visit_Sequence__c = nextSeq++
                    ));
                }
            }

            if (!newOutlets.isEmpty()) {
                insert newOutlets;
            }

            return [
                SELECT Id, Beat__c, Account__c, Account__r.Name,
                       Is_Active__c, Visit_Sequence__c
                FROM Beat_Outlet__c
                WHERE Beat__c = :beatId
                ORDER BY Visit_Sequence__c
            ];
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void removeBeatOutlet(Id beatOutletId) {
        try {
            delete [SELECT Id FROM Beat_Outlet__c WHERE Id = :beatOutletId];
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Update Outlet Sequences ─────────────────────────────────────────────

    /**
     * @description Updates the Visit_Sequence__c of outlets within a beat.
     *              Used for reordering outlets via Up/Down arrows in the UI.
     * @param outlets List of Beat_Outlet__c with Id and Visit_Sequence__c set.
     * @return Refreshed list of Beat_Outlet__c ordered by Visit_Sequence__c.
     */
    @AuraEnabled
    public static List<Beat_Outlet__c> updateOutletSequences(String outletsJson) {
        List<Beat_Outlet__c> outlets = new List<Beat_Outlet__c>();
        if (String.isNotBlank(outletsJson)) {
            for (Object o : (List<Object>) JSON.deserializeUntyped(outletsJson)) {
                outlets.add((Beat_Outlet__c) buildSObject(Beat_Outlet__c.SObjectType, (Map<String, Object>) o));
            }
        }
        return updateOutletSequencesInternal(outlets);
    }

    public static List<Beat_Outlet__c> updateOutletSequencesInternal(List<Beat_Outlet__c> outlets) {
        try {
            if (outlets == null || outlets.isEmpty()) {
                throw new AuraHandledException('No outlets provided for reordering.');
            }

            Set<Id> outletIds = new Set<Id>();
            for (Beat_Outlet__c bo : outlets) {
                if (bo.Id == null || bo.Visit_Sequence__c == null) {
                    throw new AuraHandledException('Each outlet must have an Id and Visit_Sequence__c.');
                }
                outletIds.add(bo.Id);
            }

            // Verify all outlets belong to the same beat
            Set<Id> beatIds = new Set<Id>();
            for (Beat_Outlet__c bo : [SELECT Id, Beat__c FROM Beat_Outlet__c WHERE Id IN :outletIds]) {
                beatIds.add(bo.Beat__c);
            }
            if (beatIds.size() != 1) {
                throw new AuraHandledException('All outlets must belong to the same beat.');
            }

            List<Beat_Outlet__c> toUpdate = new List<Beat_Outlet__c>();
            for (Beat_Outlet__c bo : outlets) {
                toUpdate.add(new Beat_Outlet__c(
                    Id = bo.Id,
                    Visit_Sequence__c = bo.Visit_Sequence__c
                ));
            }
            update toUpdate;

            Id beatId = new List<Id>(beatIds)[0];
            return [
                SELECT Id, Beat__c, Account__c, Account__r.Name,
                       Is_Active__c, Visit_Sequence__c
                FROM Beat_Outlet__c
                WHERE Beat__c = :beatId
                ORDER BY Visit_Sequence__c
            ];
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Clone Beat ───────────────────────────────────────────────────────────

    /**
     * @description Clones a beat and its outlet mappings. Allows assigning to
     *              a different user and/or territory.
     * @param sourceBeatId The Id of the Beat__c to clone.
     * @param newAssignedUserId The User Id for the cloned beat.
     * @param newBeatName Optional name override. If blank, appends " (Copy)".
     * @param newBeatCode Optional code override. If blank, appends "-COPY".
     * @return The newly created Beat__c record.
     */
    @AuraEnabled
    public static Beat__c cloneBeat(Id sourceBeatId, Id newAssignedUserId, String newBeatName, String newBeatCode) {
        try {
            Beat__c source = [
                SELECT Id, Name, Beat_Code__c, Day_of_Week__c, Frequency__c,
                       Territory__c, Pincode_Cluster__c, Description__c,
                       Assigned_User__c, Sequence__c, Is_Active__c
                FROM Beat__c
                WHERE Id = :sourceBeatId
                LIMIT 1
            ];

            Id assignTo = newAssignedUserId != null ? newAssignedUserId : source.Assigned_User__c;
            Beat__c cloned = new Beat__c(
                Name = String.isNotBlank(newBeatName) ? newBeatName : source.Name + ' (Copy)',
                Beat_Code__c = String.isNotBlank(newBeatCode) ? newBeatCode : source.Beat_Code__c + '-COPY',
                Day_of_Week__c = source.Day_of_Week__c,
                Frequency__c = source.Frequency__c,
                Territory__c = source.Territory__c,
                Pincode_Cluster__c = source.Pincode_Cluster__c,
                Description__c = source.Description__c,
                Assigned_User__c = assignTo,
                OwnerId = assignTo != null ? assignTo : UserInfo.getUserId(),
                Sequence__c = source.Sequence__c,
                Is_Active__c = true
            );
            insert cloned;

            // Clone all active outlet mappings
            List<Beat_Outlet__c> sourceOutlets = [
                SELECT Account__c, Visit_Sequence__c
                FROM Beat_Outlet__c
                WHERE Beat__c = :sourceBeatId AND Is_Active__c = true
                ORDER BY Visit_Sequence__c
            ];

            List<Beat_Outlet__c> clonedOutlets = new List<Beat_Outlet__c>();
            for (Beat_Outlet__c bo : sourceOutlets) {
                clonedOutlets.add(new Beat_Outlet__c(
                    Beat__c = cloned.Id,
                    Account__c = bo.Account__c,
                    Visit_Sequence__c = bo.Visit_Sequence__c,
                    Is_Active__c = true
                ));
            }
            if (!clonedOutlets.isEmpty()) {
                insert clonedOutlets;
            }

            return [
                SELECT Id, Name, Beat_Code__c, Day_of_Week__c, Frequency__c,
                       Total_Outlets__c, Pincode_Cluster__c, Description__c,
                       Territory__c, Territory__r.Name, Assigned_User__c,
                       Is_Active__c, Sequence__c
                FROM Beat__c
                WHERE Id = :cloned.Id
            ];
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Reassign Beat ────────────────────────────────────────────────────────

    /**
     * @description Wrapper to hold reassignment result including journey plan impact.
     */
    public class ReassignResult {
        @AuraEnabled public Beat__c beat;
        @AuraEnabled public Integer affectedPlanDays;
    }

    /**
     * @description Reassigns a beat to a different user. Updates the Assigned_User__c
     *              field and returns information about affected Journey Plan Days.
     * @param beatId The Beat__c Id to reassign.
     * @param newUserId The new Assigned User Id.
     * @return ReassignResult with the updated beat and count of affected plan days.
     */
    @AuraEnabled
    public static ReassignResult reassignBeat(Id beatId, Id newUserId) {
        try {
            Beat__c beat = [
                SELECT Id, Assigned_User__c
                FROM Beat__c
                WHERE Id = :beatId
                LIMIT 1
            ];

            beat.Assigned_User__c = newUserId;
            beat.OwnerId = newUserId;
            update beat;

            // Count affected Journey Plan Days (only in Draft/Active plans)
            Integer affectedDays = [
                SELECT COUNT()
                FROM Journey_Plan_Day__c
                WHERE Beat__c = :beatId
                AND Journey_Plan__r.Status__c IN ('Draft', 'Active')
            ];

            Beat__c updated = [
                SELECT Id, Name, Beat_Code__c, Day_of_Week__c, Frequency__c,
                       Total_Outlets__c, Pincode_Cluster__c, Description__c,
                       Territory__c, Territory__r.Name, Assigned_User__c,
                       Assigned_User__r.Name, Is_Active__c, Sequence__c
                FROM Beat__c
                WHERE Id = :beatId
            ];

            ReassignResult result = new ReassignResult();
            result.beat = updated;
            result.affectedPlanDays = affectedDays;
            return result;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Retrieves accounts filtered by territory with pagination and
     *              optional search. Returns accounts belonging to the same territory
     *              as the selected beat.
     * @param territoryId The Territory_Master__c Id to filter accounts.
     * @param searchTerm  Optional search string to filter by Account Name.
     * @param pageSize    Number of records per page.
     * @param pageNumber  Current page number (1-based).
     * @return AccountPageResult wrapper with accounts and total count.
     */
    @AuraEnabled
    public static AccountPageResult getAccountsByTerritory(
        Id territoryId, String searchTerm, Integer pageSize, Integer pageNumber
    ) {
        if (pageSize == null || pageSize <= 0) pageSize = 10;
        if (pageNumber == null || pageNumber <= 0) pageNumber = 1;
        Integer offset = (pageNumber - 1) * pageSize;

        String searchPattern = '';
        Boolean hasSearch = String.isNotBlank(searchTerm) && searchTerm.length() >= 2;
        if (hasSearch) {
            searchPattern = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        }

        // MDM-003: filter by current user's authorized channels (if any)
        Set<String> userChannels = MDM_ChannelMapping_Service.getCurrentUserChannels();
        List<String> channelList = new List<String>(userChannels);
        Boolean filterByChannel = BPM_FeatureToggle_Util.isEnabled('MDM-003') && !channelList.isEmpty();

        // Build dynamic WHERE clause
        List<String> conditions = new List<String>{ 'Is_Active__c = true' };
        if (territoryId != null) conditions.add('Territory__c = :territoryId');
        if (hasSearch) conditions.add('Name LIKE :searchPattern');
        if (filterByChannel) conditions.add('Channel__c IN :channelList');

        String whereClause = 'WHERE ' + String.join(conditions, ' AND ');

        Integer totalCount = Database.countQuery('SELECT COUNT() FROM Account ' + whereClause);
        List<Account> accounts = Database.query(
            'SELECT Id, Name, Type, BillingCity, BillingState, Territory__c, Channel__c ' +
            'FROM Account ' + whereClause + ' ORDER BY Name LIMIT :pageSize OFFSET :offset'
        );

        AccountPageResult result = new AccountPageResult();
        result.accounts = accounts;
        result.totalCount = totalCount;
        result.pageNumber = pageNumber;
        result.pageSize = pageSize;
        result.totalPages = (Integer)Math.ceil((Double)totalCount / pageSize);
        return result;
    }

    public class AccountPageResult {
        @AuraEnabled public List<Account> accounts;
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public Integer pageNumber;
        @AuraEnabled public Integer pageSize;
        @AuraEnabled public Integer totalPages;
    }

    // ── Calendar Day Persistence ────────────────────────────────────────────

    @AuraEnabled
    public static Journey_Plan_Day__c addBeatToCalendarDay(
        Id journeyPlanId, Id beatId, String dayOfWeek, String weekNumber, Date planDate
    ) {
        try {
            Journey_Plan__c plan = [
                SELECT Id, Status__c FROM Journey_Plan__c WHERE Id = :journeyPlanId LIMIT 1
            ];
            if (plan.Status__c == 'Approved' || plan.Status__c == 'Submitted') {
                AuraHandledException ex = new AuraHandledException('Cannot modify a plan that is submitted or approved.');
                ex.setMessage('Cannot modify a plan that is submitted or approved.');
                throw ex;
            }

            Integer outletCount = [
                SELECT COUNT() FROM Beat_Outlet__c
                WHERE Beat__c = :beatId AND Is_Active__c = true
            ];

            List<AggregateResult> maxSeq = [
                SELECT MAX(Sequence_Order__c) maxVal
                FROM Journey_Plan_Day__c
                WHERE Journey_Plan__c = :journeyPlanId
            ];
            Integer nextSeq = 1;
            if (maxSeq[0].get('maxVal') != null) {
                nextSeq = ((Decimal)maxSeq[0].get('maxVal')).intValue() + 1;
            }

            Journey_Plan_Day__c planDay = new Journey_Plan_Day__c(
                Journey_Plan__c = journeyPlanId,
                Beat__c = beatId,
                Day_of_Week__c = dayOfWeek,
                Week_Number__c = weekNumber,
                Plan_Date__c = planDate,
                Planned_Outlets__c = outletCount,
                Status__c = 'Planned',
                Sequence_Order__c = nextSeq
            );
            insert planDay;

            return [
                SELECT Id, Day_of_Week__c, Week_Number__c, Beat__c,
                       Beat__r.Name, Beat__r.Beat_Code__c, Beat__r.Total_Outlets__c,
                       Planned_Outlets__c, Sequence_Order__c, Plan_Date__c, Notes__c,
                       Journey_Plan__c
                FROM Journey_Plan_Day__c
                WHERE Id = :planDay.Id
            ];
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void removePlanDay(Id planDayId) {
        try {
            Journey_Plan_Day__c day = [
                SELECT Id, Journey_Plan__r.Status__c
                FROM Journey_Plan_Day__c WHERE Id = :planDayId LIMIT 1
            ];
            if (day.Journey_Plan__r.Status__c == 'Approved' || day.Journey_Plan__r.Status__c == 'Submitted') {
                AuraHandledException ex = new AuraHandledException('Cannot modify a plan that is submitted or approved.');
                ex.setMessage('Cannot modify a plan that is submitted or approved.');
                throw ex;
            }
            delete day;
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Generate Default Plan ───────────────────────────────────────────────

    @AuraEnabled
    public static Id generateDefaultPlan(Id userId, Id territoryId, String month, String year) {
        try {
            return BPM_JourneyPlan_Service.generateDefaultPlan(userId, territoryId, month, year);
        } catch (BPM_JourneyPlanServiceException e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Regenerate Plan ────────────────────────────────────────────────────

    /**
     * @description Regenerates a journey plan by deleting future plan days and
     *              recreating them from today using the user's current beats.
     * @param journeyPlanId  The Journey_Plan__c Id.
     * @param toDate         The new end date for the plan.
     * @param excludeHolidays  When true, exclude holiday dates from the plan.
     * @param excludeLeaves    When true, exclude approved/pending leave dates.
     * @param excludeWeekOffs  When true, exclude employee's week-off days.
     */
    @AuraEnabled
    public static void regeneratePlan(Id journeyPlanId, Date toDate,
            Boolean excludeHolidays, Boolean excludeLeaves, Boolean excludeWeekOffs) {
        try {
            // Admins (profile has ModifyAllData) can regenerate plans at any
            // status — matches the LWC behaviour where the Regenerate button
            // is visible for admins on Approved/Active plans. Non-admins stay
            // on the strict Draft/Rejected gate enforced by the service.
            Boolean adminOverride = isCurrentUserAdmin();
            BPM_JourneyPlan_Service.regeneratePlan(
                journeyPlanId, toDate, excludeHolidays, excludeLeaves, excludeWeekOffs,
                adminOverride
            );
        } catch (BPM_JourneyPlanServiceException e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Remove Beat from Plan ────────────────────────────────────────────

    /**
     * @description Removes all occurrences of a beat from a journey plan.
     * @param journeyPlanId The Journey_Plan__c Id.
     * @param beatId        The Beat__c Id to remove.
     */
    @AuraEnabled
    public static void removeBeatFromPlan(Id journeyPlanId, Id beatId) {
        try {
            Journey_Plan__c plan = [
                SELECT Id, Status__c FROM Journey_Plan__c WHERE Id = :journeyPlanId LIMIT 1
            ];
            if (plan.Status__c == 'Approved' || plan.Status__c == 'Submitted') {
                AuraHandledException ex = new AuraHandledException('Cannot modify a submitted or approved plan.');
                ex.setMessage('Cannot modify a submitted or approved plan.');
                throw ex;
            }
            List<Journey_Plan_Day__c> days = [
                SELECT Id FROM Journey_Plan_Day__c
                WHERE Journey_Plan__c = :journeyPlanId AND Beat__c = :beatId
            ];
            if (!days.isEmpty()) {
                delete days;
            }
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Generate Plan for Date Range ────────────────────────────────────────

    /**
     * @description Generates a single journey plan spanning the specified date
     *              range with configurable exclusion options. Creates one
     *              Journey_Plan__c with Effective_From/To and plan days for
     *              every working day in the range.
     * @param userId           The User (Salesperson) Id.
     * @param territoryId      The Territory_Master__c Id.
     * @param fromDate         Start date of the range.
     * @param toDate           End date of the range.
     * @param excludeHolidays  When true, exclude holiday dates from the plan.
     * @param excludeLeaves    When true, exclude approved/pending leave dates.
     * @param excludeWeekOffs  When true, exclude employee's week-off days.
     * @return The created Journey_Plan__c Id.
     */
    @AuraEnabled
    public static Id generatePlanForDateRange(
        Id userId, Id territoryId, Date fromDate, Date toDate,
        Boolean excludeHolidays, Boolean excludeLeaves, Boolean excludeWeekOffs
    ) {
        try {
            // Respect the fromDate the client sends. A previous version hard-
            // overrode this to Date.today() 'to avoid timezone mismatch', but
            // that broke the 'Generate for a future month' workflow — the LWC
            // correctly derives May 1 when the user is viewing May, and the
            // override was rewriting it back to today, causing a false-positive
            // overlap error against the current month's existing plan.
            // If the caller passes null, fall back to today.
            if (fromDate == null) {
                fromDate = Date.today();
            }
            return BPM_JourneyPlan_Service.generatePlanForDateRange(
                userId, territoryId, fromDate, toDate,
                excludeHolidays, excludeLeaves, excludeWeekOffs
            );
        } catch (BPM_JourneyPlanServiceException e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Namespace-tolerant SObject building (see saveScheme) ─────────────
    private static SObject buildSObject(Schema.SObjectType t, Map<String, Object> m) {
        SObject rec = t.newSObject();
        if (m == null) return rec;
        Map<String, Schema.SObjectField> fmap = t.getDescribe().fields.getMap();
        for (String key : m.keySet()) {
            if (key == 'sobjectType' || key == 'attributes' || m.get(key) == null) continue;
            Schema.SObjectField sf = resolveField(fmap, key);
            if (sf == null) continue; // unknown field or relationship (__r) — skip
            Schema.DescribeFieldResult dfr = sf.getDescribe();
            try { rec.put(dfr.getName(), coerceValue(dfr.getType(), m.get(key))); }
            catch (Exception e) { /* skip un-coercible value rather than fail the save */ }
        }
        return rec;
    }

    private static Schema.SObjectField resolveField(Map<String, Schema.SObjectField> fmap, String name) {
        if (String.isBlank(name) || fmap == null) return null;
        Schema.SObjectField f = fmap.get(name);
        if (f != null) return f;
        String bare = unqualify(name);
        for (String key : fmap.keySet()) {
            if (unqualify(key).equalsIgnoreCase(bare)) return fmap.get(key);
        }
        return null;
    }

    private static String unqualify(String api) {
        if (String.isBlank(api)) return api;
        if (api.endsWithIgnoreCase('__c') && api.split('__').size() >= 3) {
            return api.substringAfter('__');
        }
        return api;
    }

    private static Object coerceValue(Schema.DisplayType t, Object val) {
        if (val == null) return null;
        String s = String.valueOf(val);
        if (String.isBlank(s)) return null;
        if (t == Schema.DisplayType.Boolean) return (val instanceof Boolean) ? val : Boolean.valueOf(s);
        if (t == Schema.DisplayType.Date) return Date.valueOf(s.substring(0, 10));
        if (t == Schema.DisplayType.DateTime) return Datetime.valueOf(s.replace('T', ' ').replace('Z', ''));
        if (t == Schema.DisplayType.Double || t == Schema.DisplayType.Currency
            || t == Schema.DisplayType.Percent) return Decimal.valueOf(s);
        if (t == Schema.DisplayType.Integer) return Integer.valueOf(s);
        if (t == Schema.DisplayType.Reference || t == Schema.DisplayType.Id) return (Id) s;
        return s;
    }
}