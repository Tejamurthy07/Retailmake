trigger Target_Period_Trigger on Target_Period__c (before insert, before update) {
    // Block duplicate Target Periods. Two rules, both scoped to Is_Active__c = true:
    //   1. No two active periods with the same Start_Date__c + End_Date__c.
    //   2. No two active periods with the same Name (case-insensitive).
    List<Target_Period__c> toCheck = new List<Target_Period__c>();
    Set<Date> startDates = new Set<Date>();
    Set<Date> endDates = new Set<Date>();
    Set<String> namesLower = new Set<String>();

    for (Target_Period__c tp : Trigger.new) {
        if (tp.Is_Active__c != true) continue;
        toCheck.add(tp);
        if (tp.Start_Date__c != null) startDates.add(tp.Start_Date__c);
        if (tp.End_Date__c != null) endDates.add(tp.End_Date__c);
        if (String.isNotBlank(tp.Name)) namesLower.add(tp.Name.toLowerCase());
    }

    if (toCheck.isEmpty()) {
        return;
    }

    // Pull existing active periods that match by date OR by name in a single query.
    List<Target_Period__c> existing = [
        SELECT Id, Name, Start_Date__c, End_Date__c
        FROM Target_Period__c
        WHERE Is_Active__c = true
          AND (
              (Start_Date__c IN :startDates AND End_Date__c IN :endDates)
              OR Name IN :namesLower
          )
    ];

    // Bucket existing records for fast lookup.
    Map<String, Target_Period__c> existingByDateKey = new Map<String, Target_Period__c>();
    Map<String, Target_Period__c> existingByNameKey = new Map<String, Target_Period__c>();
    for (Target_Period__c e : existing) {
        if (e.Start_Date__c != null && e.End_Date__c != null) {
            String dateKey = String.valueOf(e.Start_Date__c) + '|' + String.valueOf(e.End_Date__c) + '|' + e.Id;
            existingByDateKey.put(dateKey, e);
        }
        if (String.isNotBlank(e.Name)) {
            String nameKey = e.Name.toLowerCase() + '|' + e.Id;
            existingByNameKey.put(nameKey, e);
        }
    }

    for (Target_Period__c tp : toCheck) {
        // 1) Same Start + End Date
        if (tp.Start_Date__c != null && tp.End_Date__c != null) {
            String datePrefix = String.valueOf(tp.Start_Date__c) + '|' + String.valueOf(tp.End_Date__c) + '|';
            for (String k : existingByDateKey.keySet()) {
                if (!k.startsWith(datePrefix)) continue;
                Target_Period__c other = existingByDateKey.get(k);
                if (other.Id == tp.Id) continue;
                tp.addError(
                    'An active period "' + other.Name + '" already exists with the same Start Date (' +
                    tp.Start_Date__c.format() + ') and End Date (' + tp.End_Date__c.format() +
                    '). Deactivate the existing period or choose different dates before saving.'
                );
                break;
            }
            if (tp.hasErrors()) continue;
        }

        // 2) Same Name (case-insensitive)
        if (String.isNotBlank(tp.Name)) {
            String namePrefix = tp.Name.toLowerCase() + '|';
            for (String k : existingByNameKey.keySet()) {
                if (!k.startsWith(namePrefix)) continue;
                Target_Period__c other = existingByNameKey.get(k);
                if (other.Id == tp.Id) continue;
                tp.Name.addError(
                    'An active period with the name "' + other.Name + '" already exists. ' +
                    'Please use a different Period Name or deactivate the existing one.'
                );
                break;
            }
        }
    }
}