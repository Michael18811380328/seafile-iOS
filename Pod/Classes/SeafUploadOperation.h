//
//  SeafUploadOperation.h
//  Pods
//
//  Created by henry on 2024/11/11.
//
#import <Foundation/Foundation.h>
#import "SeafAccountTaskQueue.h"

@class SeafUploadFile;

/**
 * SeafUploadOperation handles the network operations for uploading files.
 */
@interface SeafUploadOperation : NSOperation <SeafObservableOperation>

@property (nonatomic, strong) SeafUploadFile *uploadFile;

@property (nonatomic, assign) BOOL observersRemoved;
@property (nonatomic, assign) BOOL observersAdded;

@property (nonatomic, weak) SeafAccountTaskQueue *accountTaskQueue;

- (instancetype)initWithUploadFile:(SeafUploadFile *)uploadFile;

@end
