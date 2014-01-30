//
//  CDERevisionManager.m
//  Ensembles
//
//  Created by Drew McCormack on 25/08/13.
//  Copyright (c) 2013 Drew McCormack. All rights reserved.
//

#import "CDERevisionManager.h"
#import "NSManagedObjectModel+CDEAdditions.h"
#import "CDEEventStore.h"
#import "CDERevision.h"
#import "CDERevisionSet.h"
#import "CDEEventRevision.h"
#import "CDEStoreModificationEvent.h"

@implementation CDERevisionManager

@synthesize eventStore = eventStore;
@synthesize eventManagedObjectContext = eventManagedObjectContext;

#pragma mark Initialization

- (instancetype)initWithEventStore:(CDEEventStore *)newStore eventManagedObjectContext:(NSManagedObjectContext *)newContext
{
    self = [super init];
    if (self) {
        eventStore = newStore;
        eventManagedObjectContext = newContext;
    }
    return self;
}

- (instancetype)initWithEventStore:(CDEEventStore *)newStore
{
    return [self initWithEventStore:newStore eventManagedObjectContext:newStore.managedObjectContext];
}

#pragma mark Fetching from Event Store

+ (NSArray *)sortStoreModificationEvents:(NSArray *)events
{
    // Sort in save order. Use store id to disambiguate in unlikely event of identical timestamps.
    NSArray *sortDescriptors = @[
        [NSSortDescriptor sortDescriptorWithKey:@"globalCount" ascending:YES],
        [NSSortDescriptor sortDescriptorWithKey:@"timestamp" ascending:YES],
        [NSSortDescriptor sortDescriptorWithKey:@"eventRevision.persistentStoreIdentifier" ascending:YES]
    ];
    return [events sortedArrayUsingDescriptors:sortDescriptors];
}

- (NSArray *)fetchUncommittedStoreModificationEvents:(NSError * __autoreleasing *)error
{
    __block NSArray *result = nil;
    [eventManagedObjectContext performBlockAndWait:^{
        CDEStoreModificationEvent *lastMergeEvent = [CDEStoreModificationEvent fetchNonBaselineEventForPersistentStoreIdentifier:eventStore.persistentStoreIdentifier revisionNumber:eventStore.lastMergeRevision inManagedObjectContext:eventManagedObjectContext];
        CDEStoreModificationEvent *baseline = [CDEStoreModificationEvent fetchBaselineStoreModificationEventInManagedObjectContext:eventManagedObjectContext];
        CDERevisionSet *baselineRevisionSet = baseline.revisionSet;

        CDERevisionSet *fromRevisionSet = lastMergeEvent.revisionSet;
        if (!fromRevisionSet) { // No previous merge
            fromRevisionSet = baselineRevisionSet ? : [CDERevisionSet new];
        }
        
        // Determine which stores have appeared since last merge
        NSSet *allStoreIds = [CDEEventRevision fetchPersistentStoreIdentifiersInManagedObjectContext:eventManagedObjectContext];
        NSSet *lastMergeStoreIds = fromRevisionSet.persistentStoreIdentifiers;
        NSMutableSet *missingStoreIds = [NSMutableSet setWithSet:allStoreIds];
        [missingStoreIds minusSet:lastMergeStoreIds];
        
        NSMutableArray *events = [[NSMutableArray alloc] init];
        for (CDEEventRevision *revision in fromRevisionSet.revisions) {
            NSArray *recentEvents = [CDEStoreModificationEvent fetchNonBaselineEventsForPersistentStoreIdentifier:revision.persistentStoreIdentifier sinceRevisionNumber:revision.revisionNumber inManagedObjectContext:eventManagedObjectContext];
            [events addObjectsFromArray:recentEvents];
        }
        
        for (NSString *persistentStoreId in missingStoreIds) {
            CDERevision *baselineRevision = [baselineRevisionSet revisionForPersistentStoreIdentifier:persistentStoreId];
            CDERevisionNumber revNumber = baselineRevision ? baselineRevision.revisionNumber : -1;
            NSArray *recentEvents = [CDEStoreModificationEvent fetchNonBaselineEventsForPersistentStoreIdentifier:persistentStoreId sinceRevisionNumber:revNumber inManagedObjectContext:eventManagedObjectContext];
            [events addObjectsFromArray:recentEvents];
        }
        
        result = [self.class sortStoreModificationEvents:events];
    }];
    return result;
}

- (NSArray *)fetchStoreModificationEventsConcurrentWithEvents:(NSArray *)events error:(NSError *__autoreleasing *)error
{
    if (events.count == 0) return @[];
    
    __block NSArray *result = nil;
    [eventManagedObjectContext performBlockAndWait:^{
        CDEStoreModificationEvent *baseline = [CDEStoreModificationEvent fetchBaselineStoreModificationEventInManagedObjectContext:eventManagedObjectContext];
        CDERevisionSet *baselineRevisionSet = baseline.revisionSet;

        CDERevisionSet *minSet = [[CDERevisionSet alloc] init];
        for (CDEStoreModificationEvent *event in events) {
            CDERevisionSet *revSet = event.revisionSet;
            minSet = [minSet revisionSetByTakingStoreWiseMinimumWithRevisionSet:revSet];
        }
        
        // Add concurrent events from the stores present in the events passed in
        NSManagedObjectContext *context = [events.lastObject managedObjectContext];
        NSMutableSet *concurrentEvents = [[NSMutableSet alloc] initWithArray:events]; // Events are concurrent with themselves
        for (CDERevision *minRevision in minSet.revisions) {
            NSArray *recentEvents = [CDEStoreModificationEvent fetchNonBaselineEventsForPersistentStoreIdentifier:minRevision.persistentStoreIdentifier sinceRevisionNumber:minRevision.revisionNumber inManagedObjectContext:context];
            [concurrentEvents addObjectsFromArray:recentEvents];
        }
        
        // Determine which stores are missing from the events
        NSSet *allStoreIds = [CDEEventRevision fetchPersistentStoreIdentifiersInManagedObjectContext:context];
        NSMutableSet *missingStoreIds = [NSMutableSet setWithSet:allStoreIds];
        [missingStoreIds minusSet:minSet.persistentStoreIdentifiers];
        
        // Add events from the missing stores
        for (NSString *persistentStoreId in missingStoreIds) {
            CDERevision *baselineRevision = [baselineRevisionSet revisionForPersistentStoreIdentifier:persistentStoreId];
            CDERevisionNumber revNumber = baselineRevision ? baselineRevision.revisionNumber : -1;
            NSArray *recentEvents = [CDEStoreModificationEvent fetchNonBaselineEventsForPersistentStoreIdentifier:persistentStoreId sinceRevisionNumber:revNumber inManagedObjectContext:context];
            [concurrentEvents addObjectsFromArray:recentEvents];
        }
        
        result = [self.class sortStoreModificationEvents:concurrentEvents.allObjects];
    }];
    
    return result;
}

- (NSArray *)recursivelyFetchStoreModificationEventsConcurrentWithEvents:(NSArray *)events error:(NSError *__autoreleasing *)error
{
    NSArray *resultEvents = events;
    NSUInteger eventCount = 0;
    while (resultEvents.count != eventCount) {
        eventCount = resultEvents.count;
        resultEvents = [self fetchStoreModificationEventsConcurrentWithEvents:resultEvents error:error];
        if (!resultEvents) return nil;
    }
    return resultEvents;
}

#pragma mark Checks

- (BOOL)checkRebasingPrerequisitesForEvents:(NSArray *)events error:(NSError * __autoreleasing *)error
{
    __block BOOL result = YES;
    [eventManagedObjectContext performBlockAndWait:^{
        CDEStoreModificationEvent *baseline = [CDEStoreModificationEvent fetchBaselineStoreModificationEventInManagedObjectContext:eventManagedObjectContext];
        
        if (![self checkAllDependenciesExistForStoreModificationEvents:events]) {
            if (error) *error = [NSError errorWithDomain:CDEErrorDomain code:CDEErrorCodeMissingDependencies userInfo:nil];
            result = NO;
            return;
        }
        
        NSArray *eventsWithBaseline = events;
        if (baseline) eventsWithBaseline = [eventsWithBaseline arrayByAddingObject:baseline];
        if (![self checkContinuityOfStoreModificationEvents:eventsWithBaseline]) {
            if (error) *error = [NSError errorWithDomain:CDEErrorDomain code:CDEErrorCodeDiscontinuousRevisions userInfo:nil];
            result = NO;
            return;
        }
        
        if (![self checkModelVersionsOfStoreModificationEvents:eventsWithBaseline]) {
            if (error) *error = [NSError errorWithDomain:CDEErrorDomain code:CDEErrorCodeUnknownModelVersion userInfo:nil];
            result = NO;
            return;
        }
    }];
    
    return result;
}

- (BOOL)checkIntegrationPrequisites:(NSError * __autoreleasing *)error
{
    __block BOOL result = YES;
    [eventManagedObjectContext performBlockAndWait:^{
        NSArray *uncommittedEvents = [self fetchUncommittedStoreModificationEvents:error];
        if (!uncommittedEvents) {
            result = NO;
            return;
        }
        
        if (![self checkAllDependenciesExistForStoreModificationEvents:uncommittedEvents]) {
            if (error) *error = [NSError errorWithDomain:CDEErrorDomain code:CDEErrorCodeMissingDependencies userInfo:nil];
            result = NO;
            return;
        }
        
        NSArray *concurrentEvents = [self recursivelyFetchStoreModificationEventsConcurrentWithEvents:uncommittedEvents error:error];
        if (!concurrentEvents) {
            result = NO;
            return;
        }
        
        if (![self checkContinuityOfStoreModificationEvents:concurrentEvents]) {
            if (error) *error = [NSError errorWithDomain:CDEErrorDomain code:CDEErrorCodeDiscontinuousRevisions userInfo:nil];
            result = NO;
            return;
        }
        
        if (![self checkModelVersionsOfStoreModificationEvents:concurrentEvents]) {
            if (error) *error = [NSError errorWithDomain:CDEErrorDomain code:CDEErrorCodeUnknownModelVersion userInfo:nil];
            result = NO;
            return;
        }
    }];
    
    return result;
}

- (NSArray *)entityHashesByNameForAllVersionsInModelAtURL:(NSURL *)url
{
    NSMutableArray *entityHashDictionaries = [[NSMutableArray alloc] initWithCapacity:10];
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    NSDirectoryEnumerator *dirEnum = [fileManager enumeratorAtURL:url includingPropertiesForKeys:nil options:(NSDirectoryEnumerationSkipsSubdirectoryDescendants | NSDirectoryEnumerationSkipsHiddenFiles) errorHandler:NULL];
    for (NSURL *fileURL in dirEnum) {
        if ([[fileURL pathExtension] isEqualToString:@"mom"]) {
            NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:fileURL];
            NSDictionary *entityHashesByName = model.entityVersionHashesByName;
            if (entityHashesByName) [entityHashDictionaries addObject:entityHashesByName];
        }
    }
    return entityHashDictionaries;
}

- (BOOL)checkModelVersionsOfStoreModificationEvents:(NSArray *)events
{
    if (!self.managedObjectModelURL) return YES;
    
    NSArray *localEntityHashDictionaries = [self entityHashesByNameForAllVersionsInModelAtURL:self.managedObjectModelURL];
    for (CDEStoreModificationEvent *event in events) {
        NSString *modelVersion = event.modelVersion;
        if (!modelVersion) continue;
        
        NSDictionary *eventEntityHashes = [NSManagedObjectModel cde_entityHashesByNameFromPropertyList:modelVersion];
        if (!eventEntityHashes) continue;
        
        BOOL eventModelIsInLocalModel = NO;
        for (NSDictionary *localEntityHashes in localEntityHashDictionaries) {
            eventModelIsInLocalModel = [localEntityHashes isEqualToDictionary:eventEntityHashes];
            if (eventModelIsInLocalModel) break;
        }
        
        if (!eventModelIsInLocalModel) return NO;
    }
    
    return YES;
}

- (BOOL)checkAllDependenciesExistForStoreModificationEvents:(NSArray *)events
{
    __block BOOL result = YES;
    [eventManagedObjectContext performBlockAndWait:^{
        CDEStoreModificationEvent *baseline = [CDEStoreModificationEvent fetchBaselineStoreModificationEventInManagedObjectContext:eventManagedObjectContext];
        CDERevisionSet *baselineRevisionSet = baseline.revisionSet;
        for (CDEStoreModificationEvent *event in events) {
            NSSet *otherStoreRevs = event.eventRevisionsOfOtherStores;
            for (CDEEventRevision *otherStoreRev in otherStoreRevs) {
                // Check to see if baseline is after this event. If so, we don't need to check it, because it
                // is presumably now in the baseline.
                CDERevision *baselineRevision = [baselineRevisionSet revisionForPersistentStoreIdentifier:otherStoreRev.persistentStoreIdentifier];
                if (baselineRevision && baselineRevision.revisionNumber >= otherStoreRev.revisionNumber) continue;
                
                // Do the check
                CDEStoreModificationEvent *dependency = [CDEStoreModificationEvent fetchNonBaselineEventForPersistentStoreIdentifier:otherStoreRev.persistentStoreIdentifier revisionNumber:otherStoreRev.revisionNumber inManagedObjectContext:event.managedObjectContext];
                if (!dependency) {
                    result = NO;
                    return;
                }
            }
        }
    }];
    return result;
}

- (BOOL)checkContinuityOfStoreModificationEvents:(NSArray *)events
{
    __block BOOL result = YES;
    [eventManagedObjectContext performBlockAndWait:^{
        NSSet *stores = [NSSet setWithArray:[events valueForKeyPath:@"eventRevision.persistentStoreIdentifier"]];
        NSArray *sortDescs = @[[NSSortDescriptor sortDescriptorWithKey:@"eventRevision.revisionNumber" ascending:YES]];
        for (NSString *persistentStoreId in stores) {
            NSPredicate *predicate = [NSPredicate predicateWithFormat:@"eventRevision.persistentStoreIdentifier = %@", persistentStoreId];
            NSArray *storeEvents = [events filteredArrayUsingPredicate:predicate];
            storeEvents = [storeEvents sortedArrayUsingDescriptors:sortDescs];
            
            CDEStoreModificationEvent *firstEvent = storeEvents[0];
            CDERevisionNumber revision = firstEvent.eventRevision.revisionNumber;
            for (CDEStoreModificationEvent *event in storeEvents) {
                CDERevisionNumber nextRevision = event.eventRevision.revisionNumber;
                if (nextRevision - revision > 1) {
                    result = NO;
                    return;
                }
                revision = nextRevision;
            }
        }
    }];
    return result;
}

#pragma mark Global Count

- (CDEGlobalCount)maximumGlobalCount
{
    __block long long maxCount = -1;
    [eventManagedObjectContext performBlockAndWait:^{
        NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDEStoreModificationEvent"];
        fetch.propertiesToFetch = @[@"globalCount"];
        
        NSArray *result = [eventManagedObjectContext executeFetchRequest:fetch error:NULL];
        if (!result) @throw [NSException exceptionWithName:CDEException reason:@"Failed to get global count" userInfo:nil];
        if (result.count == 0) return;
        
        NSNumber *max = [result valueForKeyPath:@"@max.globalCount"];
        maxCount = max.longLongValue;
    }];
    return maxCount;
}

#pragma mark Maximum (Latest) Revisions

- (CDERevisionSet *)revisionSetOfMostRecentEvents
{
    __block CDERevisionSet *set = nil;
    [eventManagedObjectContext performBlockAndWait:^{
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"CDEEventRevision"];
        request.predicate = [NSPredicate predicateWithFormat:@"storeModificationEvent != NIL OR storeModificationEventForOtherStores.type = %d", CDEStoreModificationEventTypeBaseline];
        
        NSError *error;
        NSArray *allRevisions = [eventManagedObjectContext executeFetchRequest:request error:&error];
        if (!allRevisions) @throw [NSException exceptionWithName:CDEException reason:@"Fetch of revisions failed" userInfo:nil];
        
        set = [[CDERevisionSet alloc] init];
        for (CDEEventRevision *eventRevision in allRevisions) {
            NSString *identifier = eventRevision.persistentStoreIdentifier;
            CDERevision *currentRecentRevision = [set revisionForPersistentStoreIdentifier:identifier];
            if (!currentRecentRevision || currentRecentRevision.revisionNumber < eventRevision.revisionNumber) {
                if (currentRecentRevision) [set removeRevision:currentRecentRevision];
                [set addRevision:eventRevision.revision];
            }
        }
    }];
    return set;
}

#pragma mark Checkpoint Revisions

- (CDERevisionSet *)revisionSetForLastMergeOrBaseline
{
    __block CDERevisionSet *newRevisionSet = nil;
    [eventManagedObjectContext performBlockAndWait:^{
        CDERevisionNumber lastMergeRevision = eventStore.lastMergeRevision;
        NSString *persistentStoreId = self.eventStore.persistentStoreIdentifier;
        CDEStoreModificationEvent *lastMergeEvent = [CDEStoreModificationEvent fetchNonBaselineEventForPersistentStoreIdentifier:persistentStoreId revisionNumber:lastMergeRevision inManagedObjectContext:eventManagedObjectContext];
        
        newRevisionSet = lastMergeEvent.revisionSet;
        if (!newRevisionSet) {
            // No previous merge exists. Try baseline.
            CDEStoreModificationEvent *baseline = [CDEStoreModificationEvent fetchBaselineStoreModificationEventInManagedObjectContext:eventManagedObjectContext];
            if (baseline)
                newRevisionSet = baseline.revisionSet;
            else
                newRevisionSet = [[CDERevisionSet alloc] init];
        }
    }];
    return newRevisionSet;
}

#pragma mark Persistent Stores

- (NSSet *)allPersistentStoreIdentifiers
{
    CDERevisionSet *latestRevisionSet = [self revisionSetOfMostRecentEvents];
    return latestRevisionSet.persistentStoreIdentifiers;
}

@end
