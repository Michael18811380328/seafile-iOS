//
//  SeafDownloadOperation.h
//  Pods
//
//  Created by henry on 2024/11/11.
//

#import <Foundation/Foundation.h>

@class SeafFile;

/**
 * SeafDownloadOperation handles the network operations for downloading files.
 */
@interface SeafDownloadOperation : NSOperation

@property (nonatomic, strong) SeafFile *file;

- (instancetype)initWithFile:(SeafFile *)file;

@end

