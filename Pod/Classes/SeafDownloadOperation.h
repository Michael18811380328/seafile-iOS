//
//  SeafDownloadOperation.h
//  Pods
//
//  Created by henry on 2024/11/11.
//

#import <Foundation/Foundation.h>
#import "SeafAccountTaskQueue.h"

@class SeafFile;

/**
 * SeafDownloadOperation handles the network operations for downloading files.
 */
@interface SeafDownloadOperation : NSOperation <SeafObservableOperation>

@property (nonatomic, strong) SeafFile *file;

@property (nonatomic, assign) BOOL observersRemoved;
@property (nonatomic, assign) BOOL observersAdded;

- (instancetype)initWithFile:(SeafFile *)file;

@end

