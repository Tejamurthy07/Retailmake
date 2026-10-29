/**
 * @description Controller for the Holiday Management LWC component.
 *              Manages Holiday__c records: querying by year/type/territory/date range,
 *              CRUD operations, bulk import, and picklist value retrieval.
 *              Supports journey plan integration via date-range queries.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public with sharing class HolidayController {

    private static final String HOLIDAY_QUERY_FIELDS =
        'Id, Name, Holiday_Date__c, Type__c, Description__c, ' +
        'Is_Active__c, Year__c, Territory__c, Territory__r.Name';

    // ── Get Holidays (filtered) ───────────────────────────────────────────────

    /**
     * @description Retrieves active holidays for a given year, optionally filtered
     *              by holiday type and/or territory. Results are ordered by Holiday_Date__c ascending.
     * @param year        The four-digit year to query holidays for.
     * @param holidayType Optional Type__c picklist value to filter by (e.g. 'National Holiday').
     *                    Pass null or blank to return all types.
     * @param territoryId Optional Territory__c Id to filter by.
     *                    Pass null or blank to return all territories.
     * @return List of active Holiday__c records matching the criteria.
     */
    @AuraEnabled
    public static List<Holiday__c> getHolidays(Integer year, String holidayType, Id territoryId) {
        try {
            if (year == null) {
                throw new AuraHandledException('Year is required.');
            }

            String query = 'SELECT ' + HOLIDAY_QUERY_FIELDS +
                ' FROM Holiday__c WHERE Year__c = :year AND Is_Active__c = true';

            if (String.isNotBlank(holidayType)) {
                query += ' AND Type__c = :holidayType';
            }

            if (territoryId != null) {
                query += ' AND Territory__c = :territoryId';
            }

            query += ' ORDER BY Holiday_Date__c ASC';

            return Database.query(query);
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Get All Holidays for Year (Admin) ─────────────────────────────────────

    /**
     * @description Retrieves all holidays for a given year regardless of active status.
     *              Intended for admin management views where inactive records must
     *              also be visible. Optionally filtered by territory.
     * @param year The four-digit year to query holidays for.
     * @param territoryId Optional Territory__c Id to filter by.
     * @return List of all Holiday__c records for the year, ordered by date.
     */
    @AuraEnabled
    public static List<Holiday__c> getAllHolidaysForYear(Integer year, Id territoryId) {
        try {
            if (year == null) {
                throw new AuraHandledException('Year is required.');
            }

            String query = 'SELECT ' + HOLIDAY_QUERY_FIELDS +
                ' FROM Holiday__c WHERE Year__c = :year';

            if (territoryId != null) {
                query += ' AND Territory__c = :territoryId';
            }

            query += ' ORDER BY Holiday_Date__c ASC';

            return Database.query(query);
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Save Holiday ──────────────────────────────────────────────────────────

    /**
     * @description Upserts a single Holiday__c record. Automatically derives the
     *              Year__c field from the Holiday_Date__c value so callers do not
     *              need to set it manually.
     * @param holiday The Holiday__c record to upsert (with or without an Id).
     * @return The upserted Holiday__c record with all fields re-queried.
     */
    @AuraEnabled
    public static Holiday__c saveHoliday(Holiday__c holiday) {
        try {
            if (holiday.Holiday_Date__c == null) {
                throw new AuraHandledException('Holiday Date is required.');
            }

            // Auto-populate Year__c from the Holiday_Date__c
            holiday.Year__c = holiday.Holiday_Date__c.year();

            upsert holiday;

            return [
                SELECT Id, Name, Holiday_Date__c, Type__c, Description__c,
                       Is_Active__c, Year__c, Territory__c, Territory__r.Name
                FROM Holiday__c
                WHERE Id = :holiday.Id
                LIMIT 1
            ];
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Delete Holiday ────────────────────────────────────────────────────────

    /**
     * @description Deletes a Holiday__c record by its Id.
     * @param holidayId The Id of the Holiday__c record to delete.
     */
    @AuraEnabled
    public static void deleteHoliday(Id holidayId) {
        try {
            if (holidayId == null) {
                throw new AuraHandledException('Holiday Id is required.');
            }

            delete [SELECT Id FROM Holiday__c WHERE Id = :holidayId];
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Get Upcoming Holidays ─────────────────────────────────────────────────

    /**
     * @description Retrieves the next N upcoming active holidays from today's date.
     *              Useful for dashboard widgets and notification components.
     * @param limitCount The maximum number of holidays to return. Defaults to 10
     *                   if null or less than 1.
     * @return List of upcoming active Holiday__c records ordered by date.
     */
    @AuraEnabled
    public static List<Holiday__c> getUpcomingHolidays(Integer limitCount) {
        try {
            if (limitCount == null || limitCount < 1) {
                limitCount = 10;
            }

            Date today = Date.today();

            return [
                SELECT Id, Name, Holiday_Date__c, Type__c, Description__c,
                       Is_Active__c, Year__c, Territory__c, Territory__r.Name
                FROM Holiday__c
                WHERE Holiday_Date__c >= :today
                AND Is_Active__c = true
                ORDER BY Holiday_Date__c ASC
                LIMIT :limitCount
            ];
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Get Holidays Between Dates ────────────────────────────────────────────

    /**
     * @description Retrieves active holidays falling within a date range (inclusive).
     *              Designed for journey plan integration where the planner needs to
     *              know which dates are holidays within a plan period.
     * @param startDate The start of the date range (inclusive).
     * @param endDate   The end of the date range (inclusive).
     * @return List of active Holiday__c records within the range, ordered by date.
     */
    @AuraEnabled
    public static List<Holiday__c> getHolidaysBetweenDates(Date startDate, Date endDate) {
        try {
            if (startDate == null || endDate == null) {
                throw new AuraHandledException('Both start date and end date are required.');
            }

            if (startDate > endDate) {
                throw new AuraHandledException('Start date must be on or before end date.');
            }

            return [
                SELECT Id, Name, Holiday_Date__c, Type__c, Description__c,
                       Is_Active__c, Year__c, Territory__c, Territory__r.Name
                FROM Holiday__c
                WHERE Holiday_Date__c >= :startDate
                AND Holiday_Date__c <= :endDate
                AND Is_Active__c = true
                ORDER BY Holiday_Date__c ASC
            ];
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Bulk Create Holidays ──────────────────────────────────────────────────

    /**
     * @description Inserts multiple Holiday__c records in a single DML operation.
     *              Automatically sets the Year__c field on each record from its
     *              Holiday_Date__c. Intended for importing a yearly holiday calendar.
     * @param holidays List of Holiday__c records to insert.
     * @return The inserted list of Holiday__c records.
     */
    @AuraEnabled
    public static List<Holiday__c> bulkCreateHolidays(List<Holiday__c> holidays) {
        try {
            if (holidays == null || holidays.isEmpty()) {
                throw new AuraHandledException('No holiday records provided.');
            }

            // Auto-populate Year__c from Holiday_Date__c for each record
            for (Holiday__c holiday : holidays) {
                if (holiday.Holiday_Date__c == null) {
                    throw new AuraHandledException(
                        'Holiday Date is required for all records. Missing on: ' +
                        (String.isNotBlank(holiday.Name) ? holiday.Name : 'unnamed holiday')
                    );
                }
                holiday.Year__c = holiday.Holiday_Date__c.year();
            }

            insert holidays;

            Set<Id> holidayIds = new Set<Id>();
            for (Holiday__c holiday : holidays) {
                holidayIds.add(holiday.Id);
            }

            return [
                SELECT Id, Name, Holiday_Date__c, Type__c, Description__c,
                       Is_Active__c, Year__c, Territory__c, Territory__r.Name
                FROM Holiday__c
                WHERE Id IN :holidayIds
                ORDER BY Holiday_Date__c ASC
            ];
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Get Holiday Type Options ──────────────────────────────────────────────

    /**
     * @description Retrieves the available picklist values for the Type__c field
     *              on the Holiday__c object. Returns a list of maps with 'label'
     *              and 'value' keys suitable for lightning-combobox options.
     * @return List of maps containing picklist label/value pairs.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getHolidayTypeOptions() {
        try {
            List<Map<String, String>> options = new List<Map<String, String>>();

            Schema.DescribeFieldResult fieldDescribe = Holiday__c.Type__c.getDescribe();
            List<Schema.PicklistEntry> picklistEntries = fieldDescribe.getPicklistValues();

            for (Schema.PicklistEntry entry : picklistEntries) {
                if (entry.isActive()) {
                    Map<String, String> option = new Map<String, String>();
                    option.put('label', entry.getLabel());
                    option.put('value', entry.getValue());
                    options.add(option);
                }
            }

            return options;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Get Territory Options ─────────────────────────────────────────────────

    /**
     * @description Retrieves active territories from Territory_Master__c for use
     *              in combobox/filter dropdowns. Returns Id and Name.
     * @return List of active Territory_Master__c records ordered by Name.
     */
    @AuraEnabled(cacheable=true)
    public static List<Territory_Master__c> getTerritoryOptions() {
        try {
            return [
                SELECT Id, Name
                FROM Territory_Master__c
                WHERE Is_Active__c = true
                ORDER BY Name ASC
            ];
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}