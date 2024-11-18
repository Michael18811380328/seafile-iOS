//
//  SeafUploadOperation.m
//  Seafile
//
//  Created by henry on 2024/11/11.
//

// SeafUploadOperation.m

#import "SeafUploadOperation.h"
#import "SeafUploadFile.h"
#import "SeafConnection.h"
#import "SeafDir.h"
#import "Utils.h"
#import "Debug.h"
#import "SeafRepos.h"
#import "NSData+Encryption.h"
#import "SeafStorage.h"

@interface SeafUploadOperation ()

@property (nonatomic, assign) BOOL executing;
@property (nonatomic, assign) BOOL finished;

//@property (strong) NSArray *missingblocks;
//@property (strong) NSArray *allblocks;
//@property (strong) NSString *commiturl;
//@property (strong) NSString *rawblksurl;
//@property (strong) NSString *uploadpath;
//@property (nonatomic, strong) NSString *blockDir;
//@property long blkidx;

@property (nonatomic, strong) NSMutableArray<NSURLSessionTask *> *taskList;
@property (nonatomic, assign) BOOL operationCompleted;



@end

@implementation SeafUploadOperation

@synthesize executing = _executing;
@synthesize finished = _finished;

- (instancetype)initWithUploadFile:(SeafUploadFile *)uploadFile
{
    if (self = [super init]) {
        _taskList = [[NSMutableArray alloc] init];
        _uploadFile = uploadFile;
        _executing = NO;
        _finished = NO;
        
        _observersRemoved = NO;
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

    // Begin the upload process
    [self.uploadFile prepareForUploadWithCompletion:^(BOOL success, NSError *error) {
        if (!success || self.isCancelled) {
            [self completeOperation];
            return;
        }

        [self beginUpload];
    }];
}

- (void)cancel
{
    [super cancel];
    
    [self cancelAllRequests];
    
    if (self.isExecuting && !_operationCompleted) {
        // create cancel NSError
        NSError *cancelError = [NSError errorWithDomain:NSURLErrorDomain
                                                       code:NSURLErrorCancelled
                                                   userInfo:@{NSLocalizedDescriptionKey: @"The upload task was cancelled."}];
        
        [self finishUpload:false oid:nil error:cancelError];
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

#pragma mark - Upload Logic

- (void)beginUpload
{
    if (!self.uploadFile.udir.repoId || !self.uploadFile.udir.path) {
        [self finishUpload:NO oid:nil error:[Utils defaultError]];
        return;
    }

    SeafConnection *connection = self.uploadFile.udir->connection;
    NSString *repoId = self.uploadFile.udir.repoId;
    NSString *uploadPath = self.uploadFile.udir.path;

    [self upload:connection repo:repoId path:uploadPath];
}

- (void)upload:(SeafConnection *)connection repo:(NSString *)repoId path:(NSString *)uploadpath
{
    if (![Utils fileExistsAtPath:self.uploadFile.lpath]) {
        Warning("File %@ does not exist", self.uploadFile.lpath);
        [self finishUpload:NO oid:nil error:[Utils defaultError]];
        return;
    }

    SeafRepo *repo = [connection getRepo:repoId];
    if (!repo) {
        Warning("Repo %@ does not exist", repoId);
        [self finishUpload:NO oid:nil error:[Utils defaultError]];
        return;
    }

    self.uploadFile.uploading = YES;

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:self.uploadFile.lpath error:nil];
    self.uploadFile.filesize = attrs.fileSize;

    if (self.uploadFile.filesize > LARGE_FILE_SIZE) {
        Debug("Upload large file %@ by block: %lld", self.uploadFile.name, self.uploadFile.filesize);
        [self uploadLargeFileByBlocks:repo path:uploadpath];
        return;
    }

    BOOL byblock = [connection shouldLocalDecrypt:repo.repoId];
    if (byblock) {
        Debug("Upload with local decryption %@ by block: %lld", self.uploadFile.name, self.uploadFile.filesize);
        [self uploadLargeFileByBlocks:repo path:uploadpath];
        return;
    }

    NSString *uploadURL = [NSString stringWithFormat:API_URL"/repos/%@/upload-link/?p=%@", repoId, uploadpath.escapedUrl];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *connectUploadLinkTask = [connection sendRequest:uploadURL success:^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        NSString *url = [JSON stringByAppendingString:@"?ret-json=true"];
        [strongSelf uploadByFile:connection url:url path:uploadpath update:strongSelf.uploadFile.overwrite];
    } failure:^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf finishUpload:NO oid:nil error:error];
    }];
    
    [self.taskList addObject:connectUploadLinkTask];
}

- (void)uploadLargeFileByBlocks:(SeafRepo *)repo path:(NSString *)uploadpath
{
    NSMutableArray *blockids = [[NSMutableArray alloc] init];
    NSMutableArray *paths = [[NSMutableArray alloc] init];
    self.uploadFile.uploadpath = uploadpath;
    if (![self chunkFile:self.uploadFile.lpath repo:repo blockids:blockids paths:paths]) {
        Debug("Failed to chunk file");
        [self finishUpload:NO oid:nil error:[Utils defaultError]];
        return;
    }
    self.uploadFile.allblocks = blockids;
    NSString* upload_url = [NSString stringWithFormat:API_URL"/repos/%@/upload-blks-link/?p=%@", repo.repoId, uploadpath.escapedUrl];
    NSString *form = [NSString stringWithFormat: @"blklist=%@", [blockids componentsJoinedByString:@","]];
    NSURLSessionDataTask *sendBlockInfoTask = [repo->connection sendPost:upload_url form:form success:^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON) {
        Debug("upload largefile by blocks, JSON: %@", JSON);
        self.uploadFile.rawblksurl = [JSON objectForKey:@"rawblksurl"];
        self.uploadFile.commiturl = [JSON objectForKey:@"commiturl"];
        self.uploadFile.missingblocks = [JSON objectForKey:@"blklist"];
        self.uploadFile.blkidx = 0;
        [self uploadRawBlocks:repo->connection];
    } failure:^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON, NSError *error) {
        Debug("Failed to upload: %@", error);
        [self finishUpload:NO oid:nil error:error];
    }];
    
    [self.taskList addObject:sendBlockInfoTask];
}

- (void)uploadRawBlocks:(SeafConnection *)connection
{
    long count = MIN(3, (self.uploadFile.missingblocks.count - self.uploadFile.blkidx));
    Debug("upload idx %ld, total: %ld, %ld", self.uploadFile.blkidx, (long)self.uploadFile.missingblocks.count, count);
    if (count == 0) {
        [self uploadBlocksCommit:connection];
        return;
    }

    NSArray *arr = [self.uploadFile.missingblocks subarrayWithRange:NSMakeRange(self.uploadFile.blkidx, count)];
    NSMutableURLRequest *request = [[SeafConnection requestSerializer] multipartFormRequestWithMethod:@"POST" URLString:self.uploadFile.rawblksurl parameters:nil constructingBodyWithBlock:^(id<AFMultipartFormData> formData) {
        [formData appendPartWithFormData:[@"n8ba38951c9ba66418311a25195e2e380" dataUsingEncoding:NSUTF8StringEncoding] name:@"csrfmiddlewaretoken"];
        for (NSString *blockid in arr) {
            NSString *blockpath = [self blockPath:blockid];
            [formData appendPartWithFileURL:[NSURL fileURLWithPath:blockpath] name:@"file" error:nil];
        }
    } error:nil];

    __weak __typeof__ (self) wself = self;
    NSURLSessionUploadTask *blockDataUploadTask = [connection.sessionMgr uploadTaskWithStreamedRequest:request progress:^(NSProgress * _Nonnull uploadProgress) {
        __strong __typeof (wself) sself = wself;
        [sself.uploadFile updateProgressWithoutKVO:uploadProgress];
    } completionHandler:^(NSURLResponse * _Nonnull response, id  _Nullable responseObject, NSError * _Nullable error) {
        __strong __typeof (wself) sself = wself;
        Debug("Upload blocks %@", arr);
        NSHTTPURLResponse *resp __attribute__((unused)) = (NSHTTPURLResponse *)response;
        if (error) {
            Debug("Upload failed :%@,code=%ld, res=%@\n", error, (long)resp.statusCode, responseObject);
            [sself showDeserializedError:error];
            [sself finishUpload:NO oid:nil error:error];
        } else {
            sself.uploadFile.blkidx += count;
            [sself performSelector:@selector(uploadRawBlocks:) withObject:connection afterDelay:0.0];
        }
    }];
    
    [blockDataUploadTask resume];
    
    [self.taskList addObject:blockDataUploadTask];
}

-(void)showDeserializedError:(NSError *)error
{
    if (!error)
        return;
    id data = [error.userInfo objectForKey:@"com.alamofire.serialization.response.error.data"];

    if (data && [data isKindOfClass:[NSData class]]) {
        NSString *str __attribute__((unused)) = [[NSString alloc] initWithData:(NSData *)data encoding:NSUTF8StringEncoding];
        Debug("DeserializedError: %@", str);
    }
}

- (NSString *)blockPath:(NSString*)blkId
{
    return [self.blockDir stringByAppendingPathComponent:blkId];
}

- (NSString *)blockDir
{
    if (!self.uploadFile.blockDir) {
        self.uploadFile.blockDir = [SeafStorage uniqueDirUnder:SeafStorage.sharedObject.tempDir];
        [Utils checkMakeDir:self.uploadFile.blockDir];
    }
    return self.uploadFile.blockDir;
}

- (void)uploadBlocksCommit:(SeafConnection *)connection
{
    NSString *url = self.uploadFile.commiturl;
    NSMutableURLRequest *request = [[SeafConnection requestSerializer] multipartFormRequestWithMethod:@"POST" URLString:url parameters:nil constructingBodyWithBlock:^(id<AFMultipartFormData> formData) {
        [formData appendPartWithFormData:[@"n8ba38951c9ba66418311a25195e2e380" dataUsingEncoding:NSUTF8StringEncoding] name:@"csrfmiddlewaretoken"];
        if (self.uploadFile.overwrite) {
            [formData appendPartWithFormData:[@"1" dataUsingEncoding:NSUTF8StringEncoding] name:@"replace"];
        }
        [formData appendPartWithFormData:[self.uploadFile.uploadpath dataUsingEncoding:NSUTF8StringEncoding] name:@"parent_dir"];
        [formData appendPartWithFormData:[self.uploadFileName dataUsingEncoding:NSUTF8StringEncoding] name:@"file_name"];
        [formData appendPartWithFormData:[[NSString stringWithFormat:@"%lld", [Utils fileSizeAtPath1:self.uploadFile.lpath]] dataUsingEncoding:NSUTF8StringEncoding] name:@"file_size"];
        [formData appendPartWithFormData:[@"n8ba38951c9ba66418311a25195e2e380" dataUsingEncoding:NSUTF8StringEncoding] name:@"csrfmiddlewaretoken"];
        [formData appendPartWithFormData:[Utils JSONEncode:self.uploadFile.allblocks] name:@"blockids"];
        Debug("url:%@ parent_dir:%@, %@", url, self.uploadFile.uploadpath, [[NSString alloc] initWithData:[Utils JSONEncode:self.uploadFile.allblocks] encoding:NSUTF8StringEncoding]);
    } error:nil];
    
    NSURLSessionDataTask *blockCompleteTask = [connection.sessionMgr dataTaskWithRequest:request uploadProgress:^(NSProgress * _Nonnull uploadProgress) {
        
    } downloadProgress:^(NSProgress * _Nonnull downloadProgress) {
        
    } completionHandler:^(NSURLResponse * _Nonnull response, id  _Nullable responseObject, NSError * _Nullable error) {
        if (error) {
            Debug("Failed to upload blocks: %@", error);
            [self finishUpload:NO oid:nil error:error];
        } else {
            NSString *oid = nil;
            if ([responseObject isKindOfClass:[NSArray class]]) {
                oid = [[responseObject objectAtIndex:0] objectForKey:@"id"];
            } else if ([responseObject isKindOfClass:[NSDictionary class]]) {
                oid = [responseObject objectForKey:@"id"];
            }
            if (!oid || oid.length < 1) oid = [[NSUUID UUID] UUIDString];
            Debug("Successfully upload file:%@ autosync:%d oid=%@, responseObject=%@", self.uploadFileName, self.uploadFile.uploadFileAutoSync, oid, responseObject);
            [self finishUpload:YES oid:oid error:nil];
        }
    }];
    [blockCompleteTask resume];
    
    [self.taskList addObject:blockCompleteTask];
}

- (NSString *)uploadFileName {
    return [self.uploadFile.lpath lastPathComponent];
}

- (BOOL)chunkFile:(NSString *)path repo:(SeafRepo *)repo blockids:(NSMutableArray *)blockids paths:(NSMutableArray *)paths
{
    NSString *password = [repo->connection getRepoPassword:repo.repoId];
    if (repo.encrypted && !password)
        return false;
    BOOL ret = YES;
    int CHUNK_LENGTH = 2*1024*1024;
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fileHandle)
        return NO;
    while (YES) {
        @autoreleasepool {
            NSData *data = [fileHandle readDataOfLength:CHUNK_LENGTH];
            if (!data || data.length == 0) break;
            if (password)
                data = [data encrypt:password encKey:repo.encKey version:repo.encVersion];
            if (!data) {
                ret = NO;
                break;
            }
            NSString *blockid = [data SHA1];
            NSString *blockpath = [self blockPath:blockid];
            Debug("Chunk file blockid=%@, path=%@, len=%lu\n", blockid, blockpath, (unsigned long)data.length);
            [blockids addObject:blockid];
            [paths addObject:blockpath];
            [data writeToFile:blockpath atomically:YES];
        }
    }
    [fileHandle closeFile];
    return ret;
}

- (void)uploadByFile:(SeafConnection *)connection url:(NSString *)surl path:(NSString *)uploadpath update:(BOOL)update
{
    NSMutableURLRequest *request = [[SeafConnection requestSerializer] multipartFormRequestWithMethod:@"POST" URLString:surl parameters:nil constructingBodyWithBlock:^(id<AFMultipartFormData> formData) {
        if (update) {
            [formData appendPartWithFormData:[@"1" dataUsingEncoding:NSUTF8StringEncoding] name:@"replace"];
        }
        [formData appendPartWithFormData:[uploadpath dataUsingEncoding:NSUTF8StringEncoding] name:@"parent_dir"];
        [formData appendPartWithFormData:[@"n8ba38951c9ba66418311a25195e2e380" dataUsingEncoding:NSUTF8StringEncoding] name:@"csrfmiddlewaretoken"];
        NSError *error = nil;
        [formData appendPartWithFileURL:[NSURL fileURLWithPath:self.uploadFile.lpath] name:@"file" error:&error];
        if (error != nil)
            Debug("Error appending file part: %@", error);
    } error:nil];
    [self uploadRequest:request withConnection:connection];
}

- (void)uploadRequest:(NSMutableURLRequest *)request withConnection:(SeafConnection *)connection
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.uploadFile.lpath]) {
        [self finishUpload:NO oid:nil error:nil];
        return;
    }

    __weak typeof(self) weakSelf = self;
    NSURLSessionUploadTask *uploadByFileTask = [connection.sessionMgr uploadTaskWithStreamedRequest:request progress:^(NSProgress * _Nonnull uploadProgress) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf.uploadFile updateProgressWithoutKVO:uploadProgress];
    } completionHandler:^(NSURLResponse * _Nonnull response, id  _Nullable responseObject, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (error) {
            [strongSelf finishUpload:NO oid:nil error:error];
        } else {
            NSString *oid = nil;
            if ([responseObject isKindOfClass:[NSArray class]]) {
                oid = [[responseObject objectAtIndex:0] objectForKey:@"id"];
            } else if ([responseObject isKindOfClass:[NSDictionary class]]) {
                oid = [responseObject objectForKey:@"id"];
            }
            if (!oid || oid.length < 1) oid = [[NSUUID UUID] UUIDString];
            [strongSelf finishUpload:YES oid:oid error:nil];
        }
    }];

    [uploadByFileTask resume];
    
    [self.taskList addObject:uploadByFileTask];
}

//- (void)updateProgress:(NSProgress *)progress
//{
//    if (_progress) {
//        [_progress removeObserver:self
//                       forKeyPath:@"fractionCompleted"
//                          context:NULL];
//    }
//
//    _progress = progress;
//    if (progress) {
//        [_progress addObserver:self
//                    forKeyPath:@"fractionCompleted"
//                       options:NSKeyValueObservingOptionNew
//                       context:NULL];
//    }
//}

//- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
//{
//    if (![keyPath isEqualToString:@"fractionCompleted"] || ![object isKindOfClass:[NSProgress class]]) return;
//    NSProgress *progress = (NSProgress *)object;
//    float fraction = progress.fractionCompleted;
//    dispatch_async(dispatch_get_main_queue(), ^{
//        if (self.uploadFile.delegate && [self.uploadFile.delegate respondsToSelector:@selector(uploadProgress:progress:)]) {
//            [self.uploadFile.delegate uploadProgress:self.uploadFile progress:fraction];
//        }
//    });
//}

//after upload
- (void)finishUpload:(BOOL)result oid:(NSString *)oid error:(NSError *)error
{
    [self.uploadFile finishUpload:result oid:oid error:error];

    self.uploadFile.uploading = NO;
    self.uploadFile.uploaded = result;
//    [self.uploadFile cleanup];

//    dispatch_async(dispatch_get_main_queue(), ^{
//        [self.uploadFile.delegate uploadComplete:result file:self.uploadFile oid:oid];
//    });

    [self completeOperation];
}

#pragma mark - Operation State Management

- (void)completeOperation
{
    if (_operationCompleted) {
        return; // 如果已经完成操作，则不再重复执行
    }

    _operationCompleted = YES;  // 设置标志，表示操作已完成

//    if (self.uploadFile.progress) {
//        [self.uploadFile.progress removeObserver:self.uploadFile
//                       forKeyPath:@"fractionCompleted"
//                          context:NULL];
//    }
    
    [self willChangeValueForKey:@"isExecuting"];
    [self willChangeValueForKey:@"isFinished"];
    _executing = NO;
    _finished = YES;
    [self didChangeValueForKey:@"isFinished"];
    [self didChangeValueForKey:@"isExecuting"];
}

- (void)dealloc {
    if (!self.observersRemoved) {
        @try {
            [self removeObserver:self.accountTaskQueue forKeyPath:@"isExecuting"];
            [self removeObserver:self.accountTaskQueue forKeyPath:@"isFinished"];
            [self removeObserver:self.accountTaskQueue forKeyPath:@"isCancelled"];
        } @catch (NSException *exception) {
            // Handle exception
        }
        self.observersRemoved = YES;
    }
}

@end
