trigger ContentVersionTrigger on ContentVersion (after insert,before insert) {
    if(Trigger.isBefore && Trigger.isInsert){
        if (Trigger.isBefore && Trigger.isInsert) {
           // ContentVersionTriggerHandler.setFilePrefix(Trigger.new);
        }
    }
    if(Trigger.isAfter && Trigger.isInsert){
        
        List<ContentDistribution> contentDistributionsToInsert = new List<ContentDistribution>();
        
        for (ContentVersion cv : Trigger.new) {
            
            ContentDistribution dist = new ContentDistribution(
                Name = cv.Title ,
                ContentVersionId = cv.Id,
                PreferencesAllowViewInBrowser = true,
                PreferencesLinkLatestVersion = true,
                PreferencesNotifyOnVisit = false,
                PreferencesAllowOriginalDownload = true,
                PreferencesAllowPDFDownload = true
            );
            contentDistributionsToInsert.add(dist);
            
        }
        if (!contentDistributionsToInsert.isEmpty()) {
            insert contentDistributionsToInsert;
        }
        List<ContentDocumentLink> conDocList = new List<ContentDocumentLink>();
        for(ContentVersion cv : Trigger.New){
            if(cv.ExternalDocumentInfo2=='FromApp' && cv.ExternalDocumentInfo1!=null){
                ContentDocumentLink cd = new ContentDocumentLink();
                cd.contentDocumentId = cv.ContentDocumentId;
                cd.linkedEntityId = cv.ExternalDocumentInfo1;
                cd.visibility = 'AllUsers';
                conDocList.add(cd);
            }
        }
        if(conDocList.size()>0){
            insert conDocList; 
        }
        
    }
}