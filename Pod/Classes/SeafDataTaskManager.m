//  SeafBackgroundTaskManager.m
//  Pods
//
//  Created by Wei W on 4/9/17.
//
//
// SeafDataTaskManager.m

#import "SeafDataTaskManager.h"
#import "SeafUploadOperation.h"
#import "SeafDownloadOperation.h"
#import "SeafThumbOperation.h"
#import "SeafDir.h"
#import "Debug.h"
#import "SeafStorage.h"


@interface SeafDataTaskManager()

@property (nonatomic, strong) NSMutableDictionary<NSString *, SeafAccountTaskQueue *> *accountQueueDict;

@end

@implementation SeafDataTaskManager

+ (SeafDataTaskManager *)sharedObject
{
    static SeafDataTaskManager *object = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        object = [SeafDataTaskManager new];
    });
    return object;
}

- (id)init
{
    if (self = [super init]) {
        _accountQueueDict = [NSMutableDictionary new];
        _finishBlock = nil;
    }
    return self;
}

#pragma mark - Upload Tasks

- (BOOL)addUploadTask:(SeafUploadFile *)file {
    return [self addUploadTask:file priority:NSOperationQueuePriorityNormal];
}

- (BOOL)addUploadTask:(SeafUploadFile *)file priority:(NSOperationQueuePriority)priority {
    SeafAccountTaskQueue *accountQueue = [self accountQueueForConnection:file.udir->connection];
    BOOL res = [accountQueue addUploadTask:file];
    if (res && file.retryable) {
        [self saveUploadFileToTaskStorage:file];
    }
    return res;
}

- (void)removeUploadTask:(SeafUploadFile *)ufile forAccount:(SeafConnection * _Nonnull)conn
{
    SeafAccountTaskQueue *accountQueue = [self accountQueueForConnection:conn];
    [accountQueue removeUploadTask:ufile];
}

#pragma mark - Download Tasks

- (void)addFileDownloadTask:(SeafFile * _Nonnull)dfile {
    SeafAccountTaskQueue *accountQueue = [self accountQueueForConnection:dfile->connection];
    [accountQueue addFileDownloadTask:dfile];
    if (dfile.retryable) {
        [self saveFileToTaskStorage:dfile];
    }
}

#pragma mark - Thumb Tasks

- (void)addThumbTask:(SeafThumb * _Nonnull)thumb {
    SeafAccountTaskQueue *accountQueue = [self accountQueueForConnection:thumb.file->connection];
    if ([accountQueue resumeCancelledThumbTask:thumb]) {
        // 如果恢复了一个已取消的任务，则直接返回
        return;
    }
    [accountQueue addThumbTask:thumb];
}

- (void)removeThumbTaskFromAccountQueue:(SeafThumb * _Nonnull)thumb {
    SeafAccountTaskQueue *accountQueue = [self accountQueueForConnection:thumb.file->connection];
    [accountQueue removeThumbTask:thumb];
}

#pragma mark - Account Queue Management

- (SeafAccountTaskQueue *)accountQueueForConnection:(SeafConnection *)connection
{
    @synchronized(self.accountQueueDict) {
        SeafAccountTaskQueue *accountQueue = [self.accountQueueDict objectForKey:connection.accountIdentifier];
        if (!accountQueue) {
            accountQueue = [[SeafAccountTaskQueue alloc] init];
            [self.accountQueueDict setObject:accountQueue forKey:connection.accountIdentifier];
        }
        return accountQueue;
    }
}

- (void)removeAccountQueue:(SeafConnection *_Nullable)conn {
    @synchronized(self.accountQueueDict) {
        SeafAccountTaskQueue *accountQueue = [self.accountQueueDict objectForKey:conn.accountIdentifier];
        if (accountQueue) {
            [accountQueue cancelAllTasks];
            [self.accountQueueDict removeObjectForKey:conn.accountIdentifier];
        }
        [self removeAccountDownloadTaskFromStorage:conn.accountIdentifier];
        [self removeAccountUploadTaskFromStorage:conn.accountIdentifier];
    }
}

#pragma mark - Task Persistence

- (void)saveUploadFileToTaskStorage:(SeafUploadFile *)ufile {
    NSString *key = [self uploadStorageKey:ufile.accountIdentifier];
    NSDictionary *dict = [self convertTaskToDict:ufile];
    @synchronized(self) {
        NSMutableDictionary *taskStorage = [NSMutableDictionary dictionaryWithDictionary:[SeafStorage.sharedObject objectForKey:key]];
        [taskStorage setObject:dict forKey:ufile.lpath];
        [SeafStorage.sharedObject setObject:taskStorage forKey:key];
    }
}

- (void)saveFileToTaskStorage:(SeafFile *)file {
    NSString *key = [self downloadStorageKey:file.accountIdentifier];
    NSDictionary *dict = [self convertTaskToDict:file];
    @synchronized(self) {
        NSMutableDictionary *taskStorage = [NSMutableDictionary dictionaryWithDictionary:[SeafStorage.sharedObject objectForKey:key]];
        [taskStorage setObject:dict forKey:file.uniqueKey];
        [SeafStorage.sharedObject setObject:taskStorage forKey:key];
    }
}

- (void)removeUploadFileTaskInStorage:(SeafUploadFile *)ufile {
    NSString *key = [self uploadStorageKey:ufile.accountIdentifier];
    @synchronized(self) {
        NSMutableDictionary *taskStorage = [NSMutableDictionary dictionaryWithDictionary:[SeafStorage.sharedObject objectForKey:key]];
        [taskStorage removeObjectForKey:ufile.lpath];
        [SeafStorage.sharedObject setObject:taskStorage forKey:key];
    }
}


- (NSString *)downloadStorageKey:(NSString *)accountIdentifier {
    return [NSString stringWithFormat:@"%@/%@", KEY_DOWNLOAD, accountIdentifier];
}

- (NSString *)uploadStorageKey:(NSString *)accountIdentifier {
    return [NSString stringWithFormat:@"%@/%@", KEY_UPLOAD, accountIdentifier];
}

- (NSMutableDictionary *)convertTaskToDict:(id)task {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if ([task isKindOfClass:[SeafFile class]]) {
        SeafFile *file = (SeafFile *)task;
        [Utils dict:dict setObject:file.oid forKey:@"oid"];
        [Utils dict:dict setObject:file.repoId forKey:@"repoId"];
        [Utils dict:dict setObject:file.name forKey:@"name"];
        [Utils dict:dict setObject:file.path forKey:@"path"];
        [Utils dict:dict setObject:[NSNumber numberWithLongLong:file.mtime] forKey:@"mtime"];
        [Utils dict:dict setObject:[NSNumber numberWithLongLong:file.filesize] forKey:@"size"];
    } else if ([task isKindOfClass:[SeafUploadFile class]]) {
        SeafUploadFile *ufile = (SeafUploadFile *)task;
        [Utils dict:dict setObject:ufile.lpath forKey:@"lpath"];
        [Utils dict:dict setObject:[NSNumber numberWithBool:ufile.overwrite] forKey:@"overwrite"];
        [Utils dict:dict setObject:ufile.udir.oid forKey:@"oid"];
        [Utils dict:dict setObject:ufile.udir.repoId forKey:@"repoId"];
        [Utils dict:dict setObject:ufile.udir.name forKey:@"name"];
        [Utils dict:dict setObject:ufile.udir.path forKey:@"path"];
        [Utils dict:dict setObject:ufile.udir.perm forKey:@"perm"];
        [Utils dict:dict setObject:ufile.udir.mime forKey:@"mime"];
        if (ufile.isEditedFile) {
            [Utils dict:dict setObject:[NSNumber numberWithBool:ufile.isEditedFile] forKey:@"isEditedFile"];
            [Utils dict:dict setObject:ufile.editedFilePath forKey:@"editedFilePath"];
            [Utils dict:dict setObject:ufile.editedFileRepoId forKey:@"editedFileRepoId"];
            [Utils dict:dict setObject:ufile.editedFileOid forKey:@"editedFileOid"];
        }
        [Utils dict:dict setObject:[NSNumber numberWithBool:ufile.isUploaded] forKey:@"uploaded"];
    }
    return dict;
}

#pragma mark - Starting Unfinished Tasks

- (void)startLastTimeUnfinshTaskWithConnection:(SeafConnection *)conn {
    NSString *downloadKey = [self downloadStorageKey:conn.accountIdentifier];
    NSDictionary *downloadTasks = [SeafStorage.sharedObject objectForKey:downloadKey];
    if (downloadTasks.allValues.count > 0) {
        for (NSDictionary *dict in downloadTasks.allValues) {
            NSNumber *mtimeNumber = [dict objectForKey:@"mtime"];
            
            NSString *oid = [Utils getNewOidFromMtime:[mtimeNumber longLongValue] repoId:[dict objectForKey:@"repoId"] path:[dict objectForKey:@"path"]];
            
            SeafFile *file = [[SeafFile alloc] initWithConnection:conn oid:oid repoId:[dict objectForKey:@"repoId"] name:[dict objectForKey:@"name"] path:[dict objectForKey:@"path"] mtime:[[dict objectForKey:@"mtime"] longLongValue] size:[[dict objectForKey:@"size"] longLongValue]];
            [self addFileDownloadTask:file];
        }
    }
    
    NSString *uploadKey = [self uploadStorageKey:conn.accountIdentifier];
    NSMutableDictionary *uploadTasks = [NSMutableDictionary dictionaryWithDictionary: [SeafStorage.sharedObject objectForKey:uploadKey]];
    NSMutableArray *toDelete = [NSMutableArray new];
    for (NSString *key in uploadTasks) {
        NSDictionary *dict = [uploadTasks objectForKey:key];
        NSString *lpath = [dict objectForKey:@"lpath"];
        if (![Utils fileExistsAtPath:lpath]) {
            [toDelete addObject:key];
            continue;
        }
        SeafUploadFile *ufile = [[SeafUploadFile alloc] initWithPath:lpath];
        if ([[dict objectForKey:@"uploaded"] boolValue]) {
            [ufile cleanup];
            [toDelete addObject:key];
            continue;
        }
        ufile.overwrite = [[dict objectForKey:@"overwrite"] boolValue];
        SeafDir *udir = [[SeafDir alloc] initWithConnection:conn oid:[dict objectForKey:@"oid"] repoId:[dict objectForKey:@"repoId"] perm:[dict objectForKey:@"perm"] name:[dict objectForKey:@"name"] path:[dict objectForKey:@"path"] mime:[dict objectForKey:@"mime"]];
        ufile.udir = udir;
        
        NSNumber *isEditedFileNumber = [dict objectForKey:@"isEditedFile"];
        BOOL isEditedUploadFile = NO;
        if (isEditedFileNumber != nil && [isEditedFileNumber isKindOfClass:[NSNumber class]]) {
            isEditedUploadFile = [isEditedFileNumber boolValue];
        }
        
        if (isEditedUploadFile) {
            ufile.isEditedFile = YES;
            ufile.editedFilePath = [dict objectForKey:@"editedFilePath"];
            ufile.editedFileRepoId = [dict objectForKey:@"editedFileRepoId"];
            ufile.editedFileOid = [dict objectForKey:@"editedFileOid"];
        }
        [self addUploadTask:ufile];
    }
    if (toDelete.count > 0) {
        for (NSString *key in toDelete) {
            [uploadTasks removeObjectForKey:key];
        }
        [SeafStorage.sharedObject setObject:uploadTasks forKey:uploadKey];
    }
}

#pragma mark - Canceling Tasks

//- (void)cancelAutoSyncTasks:(SeafConnection *)conn {
//    SeafAccountTaskQueue *accountQueue = [self accountQueueForConnection:conn];
//    [accountQueue.uploadQueue cancelAllOperations];
//}

- (void)cancelAllDownloadTasks:(SeafConnection * _Nonnull)conn {
    SeafAccountTaskQueue *accountQueue = [self accountQueueForConnection:conn];
//    [accountQueue.downloadQueue cancelAllOperations];
    [accountQueue cancelAllDownloadTasks];
    [self removeAccountDownloadTaskFromStorage:conn.accountIdentifier];
}

//取消任务并且清除缓存
- (void)cancelAllUploadTasks:(SeafConnection * _Nonnull)conn {
    SeafAccountTaskQueue *accountQueue = [self accountQueueForConnection:conn];
//    [accountQueue.uploadQueue cancelAllOperations];
    [accountQueue cancelAllUploadTasks];
    [self removeAccountUploadTaskFromStorage:conn.accountIdentifier];
}

#pragma mark - Helper Methods

- (void)removeAccountDownloadTaskFromStorage:(NSString *)accountIdentifier {
    NSString *key = [self downloadStorageKey:accountIdentifier];
    [SeafStorage.sharedObject removeObjectForKey:key];
}

- (void)removeAccountUploadTaskFromStorage:(NSString *)accountIdentifier {
    NSString *key = [self uploadStorageKey:accountIdentifier];
    [SeafStorage.sharedObject removeObjectForKey:key];
}

- (NSArray * _Nullable)getUploadTasksInDir:(SeafDir *)dir connection:(SeafConnection * _Nonnull)connection {
    SeafAccountTaskQueue *accountQueue = [self accountQueueForConnection:connection];
    return [accountQueue getUploadTasksInDir:dir];
}

//从connection获取队列状态
- (NSArray *)getOngoingUploadTasksFromConnection: (SeafConnection *)connection {
    SeafAccountTaskQueue *accountQueue = [self accountQueueForConnection:connection];
    NSMutableArray *ongoingTasks = [NSMutableArray array];
    for (SeafUploadOperation *operation in accountQueue.uploadQueue.operations) {
        if (operation.isExecuting && !operation.isFinished) {
            [ongoingTasks addObject:operation.uploadFile];
        }
    }
    return ongoingTasks;
}

// get the on going download tasks
- (NSArray *)getOngoingDownloadTasks: (SeafConnection *)connection {
    SeafAccountTaskQueue *accountQueue = [self accountQueueForConnection:connection];
    NSMutableArray *ongoingTasks = [NSMutableArray array];
    for (SeafDownloadOperation *operation in accountQueue.downloadQueue.operations) {
        if (operation.isExecuting && !operation.isFinished) {
            [ongoingTasks addObject:operation.file];
        }
    }
    return ongoingTasks;
}

// 获取已完成的上传任务
- (NSArray *)getCompletedUploadTasks: (SeafConnection *)connection {
    SeafAccountTaskQueue *accountQueue = [self accountQueueForConnection:connection];
    NSMutableArray *completedTasks = [NSMutableArray array];
    for (SeafUploadOperation *operation in accountQueue.uploadQueue.operations) {
        if (operation.isFinished && !operation.isCancelled) {
            [completedTasks addObject:operation.uploadFile];
        }
    }
    return completedTasks;
}

// 获取已完成的下载任务
- (NSArray *)getCompletedDownloadTasks: (SeafConnection *)connection {
    SeafAccountTaskQueue *accountQueue = [self accountQueueForConnection:connection];
    NSMutableArray *completedTasks = [NSMutableArray array];
    for (SeafDownloadOperation *operation in accountQueue.downloadQueue.operations) {
        if (operation.isFinished && !operation.isCancelled) {
            [completedTasks addObject:operation.file];
        }
    }
    return completedTasks;
}

@end
