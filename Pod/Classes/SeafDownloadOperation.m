//
//  SeafDownloadOperation.m
//  Seafile
//
//  Created by henry on 2024/11/16.
//

#import "SeafDownloadOperation.h"
#import "SeafFile.h"
#import "SeafConnection.h"
#import "Utils.h"
#import "Debug.h"
#import "SeafStorage.h"
#import "SeafBase.h"
#import "SeafDir.h"
#import "SeafRepos.h"
#import "NSData+Encryption.h"

@interface SeafDownloadOperation ()

@property (nonatomic, assign) BOOL executing;
@property (nonatomic, assign) BOOL finished;

//@property (strong) NSProgress *progress;
@property (nonatomic, strong) NSMutableArray<NSURLSessionTask *> *taskList;
@property (nonatomic, assign) BOOL operationCompleted;

@end

@implementation SeafDownloadOperation

@synthesize executing = _executing;
@synthesize finished = _finished;

- (instancetype)initWithFile:(SeafFile *)file
{
    if (self = [super init]) {
        _file = file;
        _executing = NO;
        _finished = NO;
        _taskList = [NSMutableArray array];
    }
    return self;
}

#pragma mark - NSOperation Overrides

- (BOOL)isAsynchronous
{
    return YES;
}

- (BOOL)isExecuting
{
    return _executing;
}

- (BOOL)isFinished
{
    return _finished;
}

- (void)start
{
    [self.taskList removeAllObjects];
    
    if (self.isCancelled) {
        [self completeOperation];
        return;
    }

    [self willChangeValueForKey:@"isExecuting"];
    _executing = YES;
    [self didChangeValueForKey:@"isExecuting"];

    [self beginDownload];
}

- (void)cancel
{
    [super cancel];
    [self cancelAllRequests];
    self.file.state = SEAF_DENTRY_FAILURE;

    if (self.isExecuting && !_operationCompleted) {
        NSError *cancelError = [NSError errorWithDomain:NSURLErrorDomain
                                                   code:NSURLErrorCancelled
                                               userInfo:@{NSLocalizedDescriptionKey: @"The download task was cancelled."}];
        [self finishDownload:NO error:cancelError ooid:self.file.ooid];
        [self completeOperation];
    }
}

- (void)cancelAllRequests
{
    for (NSURLSessionTask *task in self.taskList) {
        [task cancel];
    }
    [self.taskList removeAllObjects];
}

#pragma mark - Download Logic

- (void)beginDownload
{
    if (!self.file.repoId || !self.file.path) {
        [self finishDownload:NO error:[Utils defaultError] ooid:self.file.ooid];
        return;
    }

    SeafConnection *connection = self.file->connection;
    self.file.state = SEAF_DENTRY_LOADING;

    if ([connection shouldLocalDecrypt:self.file.repoId] || self.file.filesize > LARGE_FILE_SIZE) {
        Debug("Download file %@ by blocks: %lld", self.file.name, self.file.filesize);
        [self downloadByBlocks:connection];
    } else {
        [self downloadByFile:connection];
    }
}

- (void)downloadByFile:(SeafConnection *)connection
{
    NSString *url = [NSString stringWithFormat:API_URL"/repos/%@/file/?p=%@", self.file.repoId, [self.file.path escapedUrl]];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *getDownloadUrlTask = [connection sendRequest:url
                                                               success:^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *downloadUrl = JSON;
        NSString *curId = [Utils getNewOidFromMtime:strongSelf.file.mtime repoId:strongSelf.file.repoId path:strongSelf.file.path];
        if (!curId) curId = strongSelf.file.oid;
        if ([[NSFileManager defaultManager] fileExistsAtPath:[SeafStorage.sharedObject documentPath:curId]]) {
            Debug("File %@ already exists, curId=%@, ooid=%@", strongSelf.file.name, curId, strongSelf.file.ooid);
            [strongSelf finishDownload:YES error:nil ooid:curId];
            return;
        }
        @synchronized (strongSelf.file) {
            if (strongSelf.file.state != SEAF_DENTRY_LOADING) {
                Info("Download file %@ already canceled", strongSelf.file.name);
                [strongSelf finishDownload:YES error:nil ooid:nil];//Only completed, no further processing
                return;
            }
            if (strongSelf.file.downloadingFileOid) {
                Debug("Already downloading %@", strongSelf.file.downloadingFileOid);
                [strongSelf finishDownload:YES error:nil ooid:nil];
                return;
            }
            strongSelf.file.downloadingFileOid = curId;
        }
        [strongSelf.file downloadProgress:0];
        [strongSelf downloadFileWithUrl:downloadUrl connection:connection];
    } failure:^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.file.state = SEAF_DENTRY_INIT;
        [strongSelf.file downloadFailed:error];//temporary put this code here.
        [strongSelf finishDownload:NO error:error ooid:nil];
    }];
    
    [self.taskList addObject:getDownloadUrlTask];
}

- (void)downloadFileWithUrl:(NSString *)url connection:(SeafConnection *)connection
{
    url = [url stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    NSURLRequest *downloadRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:DEFAULT_TIMEOUT];

    NSString *target = [SeafStorage.sharedObject documentPath:self.file.downloadingFileOid];
    Debug("Download file %@ %@ from %@, target:%@", self.file.name, self.file.downloadingFileOid, url, target);

    __weak typeof(self) weakSelf = self;
    NSURLSessionDownloadTask *downloadTask = [connection.sessionMgr downloadTaskWithRequest:downloadRequest
                                                                                   progress:^(NSProgress * _Nonnull downloadProgress) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf updateProgress:downloadProgress];
    } destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
        return [NSURL fileURLWithPath:[target stringByAppendingPathExtension:@"tmp"]];
    } completionHandler:^(NSURLResponse * _Nonnull response, NSURL * _Nullable filePath, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            [strongSelf finishDownload:YES error:nil ooid:nil];
            return;
        }
        if (!strongSelf.file.downloadingFileOid) {
            Info("Download file %@ already canceled", strongSelf.file.name);
            [strongSelf finishDownload:YES error:nil ooid:nil];
            return;
        }
        if (error) {
            Debug("Failed to download %@, error=%@, %ld", strongSelf.file.name, [error localizedDescription], (long)((NSHTTPURLResponse *)response).statusCode);
            [strongSelf.file downloadFailed:error];//temporary
            [strongSelf finishDownload:NO error:error ooid:nil];
        } else {
            Debug("Successfully downloaded file:%@, %@", strongSelf.file.name, downloadRequest.URL);
            if (![filePath.path isEqualToString:target]) {
                [Utils removeFile:target];
                [[NSFileManager defaultManager] moveItemAtPath:filePath.path toPath:target error:nil];
            }
            [strongSelf finishDownload:YES error:nil ooid:strongSelf.file.downloadingFileOid];
        }
    }];
    [downloadTask resume];
    [self.taskList addObject:downloadTask];
}

- (void)downloadByBlocks:(SeafConnection *)connection
{
    NSString *url = [NSString stringWithFormat:API_URL"/repos/%@/file/?p=%@&op=downloadblks", self.file.repoId, [self.file.path escapedUrl]];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *getBlockInfoTask = [connection sendRequest:url
                                                             success:^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *curId = JSON[@"file_id"];
        NSString *oid = [Utils getNewOidFromMtime:strongSelf.file.mtime repoId:strongSelf.file.repoId path:strongSelf.file.path];
        if ([[NSFileManager defaultManager] fileExistsAtPath:[SeafStorage.sharedObject documentPath:oid]]) {
            Debug("Already up-to-date oid=%@", strongSelf.file.ooid);
//            [strongSelf.file finishDownload:oid];
            [strongSelf finishDownload:YES error:nil ooid:oid];
            return;
        }
        @synchronized (strongSelf.file) {
            if (strongSelf.file.state != SEAF_DENTRY_LOADING) {
                Info("Download file %@ already canceled", strongSelf.file.name);
                [strongSelf finishDownload:YES error:nil ooid:nil];
                return;
            }
            strongSelf.file.downloadingFileOid = curId;
        }
        [strongSelf.file downloadProgress:0];
        strongSelf.file.blkids = JSON[@"blklist"];
        if (strongSelf.file.blkids.count <= 0) {
            [@"" writeToFile:[SeafStorage.sharedObject documentPath:strongSelf.file.downloadingFileOid] atomically:YES encoding:NSUTF8StringEncoding error:nil];
//            [strongSelf.file finishDownload:strongSelf.file.downloadingFileOid];
            [strongSelf finishDownload:YES error:nil ooid:strongSelf.file.downloadingFileOid];
        } else {
            strongSelf.file.index = 0;
            Debug("blks=%@", strongSelf.file.blkids);
            [strongSelf downloadBlocks];
//            [strongSelf finishDownload:YES error:nil]; // Assuming downloadBlocks handles the rest
        }
    } failure:^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.file.state = SEAF_DENTRY_FAILURE;
        [strongSelf.file downloadFailed:error];
        [strongSelf finishDownload:NO error:error ooid:nil];
    }];
    [self.taskList addObject:getBlockInfoTask];
}

- (void)downloadBlocks
{
    if (!self.file.isDownloading) return;
    NSString *blk_id = [self.file.blkids objectAtIndex:self.file.index];
    if ([[NSFileManager defaultManager] fileExistsAtPath:[SeafStorage.sharedObject blockPath:blk_id]])
        return [self finishBlock:blk_id];

    NSString *link = [NSString stringWithFormat:API_URL"/repos/%@/files/%@/blks/%@/download-link/", self.file.repoId, self.file.downloadingFileOid, blk_id];
    Debug("link=%@", link);
    @weakify(self);
    NSURLSessionDataTask *task = [self.file->connection sendRequest:link success:
     ^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON) {
        @strongify(self);
         NSString *url = JSON;
         [self donwloadBlock:blk_id fromUrl:url];
     } failure:^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON, NSError *error) {
         @strongify(self);
         Warning("error=%@", error);
         [self.file failedDownload:error];
         [self finishDownload:false error:error ooid:nil];
     }];
    [self.taskList addObject:task];
}

- (void)donwloadBlock:(NSString *)blk_id fromUrl:(NSString *)url
{
    if (!self.file.isDownloading) return;
    NSURLRequest *downloadRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:url]];
    Debug("URL: %@", downloadRequest.URL);

    NSString *target = [SeafStorage.sharedObject blockPath:blk_id];
    __weak __typeof__ (self) wself = self;
    NSURLSessionDownloadTask *task = [self.file->connection.sessionMgr downloadTaskWithRequest:downloadRequest progress:^(NSProgress * _Nonnull downloadProgress) {
        __strong __typeof (wself) sself = wself;
        sself.file.progress = downloadProgress;
        [sself.file.progress addObserver:sself.file
                    forKeyPath:@"fractionCompleted"
                       options:NSKeyValueObservingOptionNew
                       context:NULL];
    } destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
        return [NSURL fileURLWithPath:target];
    } completionHandler:^(NSURLResponse * _Nonnull response, NSURL * _Nullable filePath, NSError * _Nullable error) {
        __strong __typeof (wself) sself = wself;
        if (error) {
            Warning("error=%@", error);
            [sself.file failedDownload:error];
            [sself finishDownload:false error:error ooid:nil];
        } else {
            Debug("Successfully downloaded file %@ block:%@, filePath:%@", sself.name, blk_id, filePath);
            if (![filePath.path isEqualToString:target]) {
                [[NSFileManager defaultManager] removeItemAtPath:target error:nil];
                [[NSFileManager defaultManager] moveItemAtPath:filePath.path toPath:target error:nil];
            }
            [sself finishBlock:blk_id];
        }
    }];
    
    [task resume];
    [self.taskList addObject:task];
}

- (void)finishBlock:(NSString *)blkid
{
    if (!self.file.downloadingFileOid) {
        Debug("file download has beeen canceled.");
        [self.file removeBlock:blkid];
        return;
    }
    self.file.index ++;
    if (self.file.index >= self.file.blkids.count) {
        if ([self checkoutFile] < 0) {
            Debug("Faile to checkout out file %@\n", self.file.downloadingFileOid);
            self.file.index = 0;
            for (NSString *blk_id in self.file.blkids)
                [self.file removeBlock:blk_id];
            NSError *error = [NSError errorWithDomain:@"Faile to checkout out file" code:-1 userInfo:nil];
            [self.file failedDownload:error];
            [self finishDownload:NO error:error ooid:nil];
            return;
        }
        [self finishDownload:YES error:nil ooid:self.file.downloadingFileOid];
        return;
    }
    [self performSelector:@selector(downloadBlocks) withObject:nil afterDelay:0.0];
}

- (int)checkoutFile
{
    NSString *password = nil;
    SeafRepo *repo = [self.file->connection getRepo:self.file.repoId];
    if (repo.encrypted) {
        password = [self.file->connection getRepoPassword:self.file.repoId];
    }
    NSString *tmpPath = [self.file downloadTempPath:self.file.downloadingFileOid];
    if (![[NSFileManager defaultManager] fileExistsAtPath:tmpPath])
        [[NSFileManager defaultManager] createFileAtPath:tmpPath contents: nil attributes: nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:tmpPath];
    [handle truncateFileAtOffset:0];
    for (NSString *blk_id in self.file.blkids) {
        NSData *data = [[NSData alloc] initWithContentsOfFile:[SeafStorage.sharedObject blockPath:blk_id]];
        if (password)
            data = [data decrypt:password encKey:repo.encKey version:repo.encVersion];
        if (!data)
            return -1;
        [handle writeData:data];
    }
    [handle closeFile];
    if (!self.file.downloadingFileOid)
        return -1;
    
    self.file.downloadingFileOid = [Utils getNewOidFromMtime:self.file.mtime repoId:self.file.repoId path:self.file.path];
    
    [[NSFileManager defaultManager] moveItemAtPath:tmpPath toPath:[SeafStorage.sharedObject documentPath:self.file.downloadingFileOid] error:nil];
    return 0;
}

- (void)updateProgress:(NSProgress *)progress
{
    if (self.file.progress) {
        [self.file.progress removeObserver:self.file forKeyPath:@"fractionCompleted" context:NULL];
    }

    self.file.progress = progress;
    if (progress) {
        [self.file.progress addObserver:self.file
                    forKeyPath:@"fractionCompleted"
                       options:NSKeyValueObservingOptionNew
                       context:NULL];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (![keyPath isEqualToString:@"fractionCompleted"] || ![object isKindOfClass:[NSProgress class]]) return;
    NSProgress *progress = (NSProgress *)object;
    float fraction = progress.fractionCompleted;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.file downloadProgress:fraction];
    });
}

- (void)finishDownload:(BOOL)success error:(NSError *)error ooid:(NSString *)ooid
{
    self.file.isDownloading = NO;
    self.file.downloaded = success;
    if (ooid != nil) {
        [self.file finishDownload:ooid];
    }
    [self completeOperation];
}

#pragma mark - Operation State Management

- (void)completeOperation
{
    if (_operationCompleted) {
        return; // 如果已经完成操作，则不再重复执行
    }

    _operationCompleted = YES;  // 设置标志，表示操作已完成

    [self willChangeValueForKey:@"isExecuting"];
    [self willChangeValueForKey:@"isFinished"];
    _executing = NO;
    _finished = YES;
    [self didChangeValueForKey:@"isFinished"];
    [self didChangeValueForKey:@"isExecuting"];
}

@end
