trigger Target_Trigger on Target__c (before insert, before update) {
    Map<Integer, String> monthNames = new Map<Integer, String>{
        1 => 'January', 2 => 'February', 3 => 'March', 4 => 'April',
        5 => 'May', 6 => 'June', 7 => 'July', 8 => 'August',
        9 => 'September', 10 => 'October', 11 => 'November', 12 => 'December'
    };

    for (Target__c t : Trigger.new) {
        if (t.Period_Start__c != null) {
            if (t.Period_Month__c == null) {
                t.Period_Month__c = monthNames.get(t.Period_Start__c.month());
            }
            if (t.Period_Year__c == null) {
                t.Period_Year__c = String.valueOf(t.Period_Start__c.year());
            }
        }
    }
}