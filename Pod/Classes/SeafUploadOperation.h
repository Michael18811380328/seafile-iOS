//
//  SeafUploadOperation.h
//  Pods
//
//  Created by henry on 2024/11/11.
//
#import <Foundation/Foundation.h>
#import "SeafAccountTaskQueue.h"
#import "SeafBaseOperation.h"

//#define UPLOAD_MAX_RETRY_COUNT 5
#define UPLOAD_RETRY_DELAY 5

@class SeafUploadFile;

/**
 * SeafUploadOperation handles the network operations for uploading files.
 */
@interface SeafUploadOperation : SeafBaseOperation

@property (nonatomic, strong) SeafUploadFile *uploadFile;

//@property (nonatomic, assign) BOOL observersRemoved;
//@property (nonatomic, assign) BOOL observersAdded;
//
//// retry
//@property (nonatomic, assign) NSInteger retryCount;
//@property (nonatomic, assign) NSInteger maxRetryCount;
//@property (nonatomic, assign) NSTimeInterval retryDelay;

//@property (nonatomic, weak) SeafAccountTaskQueue *accountTaskQueue;

- (instancetype)initWithUploadFile:(SeafUploadFile *)uploadFile;

@end
