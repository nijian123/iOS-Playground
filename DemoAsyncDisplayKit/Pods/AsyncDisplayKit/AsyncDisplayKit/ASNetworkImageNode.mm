/* Copyright (c) 2014-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "ASNetworkImageNode.h"

#import "ASBasicImageDownloader.h"
#import "ASDisplayNode+Subclasses.h"
#import "ASDisplayNode+FrameworkPrivate.h"
#import "ASEqualityHelpers.h"
#import "ASThread.h"

@interface ASNetworkImageNode ()
{
  ASDN::RecursiveMutex _lock;
  __weak id<ASImageCacheProtocol> _cache;
  __weak id<ASImageDownloaderProtocol> _downloader;

  // Only access any of these with _lock.
  __weak id<ASNetworkImageNodeDelegate> _delegate;

  NSURL *_URL;
  UIImage *_defaultImage;

  NSUUID *_cacheUUID;
  id _imageDownload;

  BOOL _imageLoaded;
}
@end

@implementation ASNetworkImageNode

- (instancetype)initWithCache:(id<ASImageCacheProtocol>)cache downloader:(id<ASImageDownloaderProtocol>)downloader
{
  if (!(self = [super init]))
    return nil;

  _cache = cache;
  _downloader = downloader;
  _shouldCacheImage = YES;
  self.shouldBypassEnsureDisplay = YES;

  return self;
}

- (instancetype)init
{
  return [self initWithCache:nil downloader:[ASBasicImageDownloader sharedImageDownloader]];
}

- (void)dealloc
{
  [self _cancelImageDownload];
}

#pragma mark - Public methods -- must lock

- (void)setURL:(NSURL *)URL
{
  [self setURL:URL resetToDefault:YES];
}

- (void)setURL:(NSURL *)URL resetToDefault:(BOOL)reset
{
  ASDN::MutexLocker l(_lock);

  if (ASObjectIsEqual(URL, _URL)) {
    return;
  }

  [self _cancelImageDownload];
  _imageLoaded = NO;

  _URL = URL;

  if (reset || _URL == nil)
    self.image = _defaultImage;
  
  if (self.interfaceState & ASInterfaceStateFetchData) {
    [self fetchData];
  }
}

- (NSURL *)URL
{
  ASDN::MutexLocker l(_lock);
  return _URL;
}

- (void)setDefaultImage:(UIImage *)defaultImage
{
  ASDN::MutexLocker l(_lock);

  if (ASObjectIsEqual(defaultImage, _defaultImage)) {
    return;
  }
  _defaultImage = defaultImage;

  if (!_imageLoaded) {
    self.image = _defaultImage;
  }
}

- (UIImage *)defaultImage
{
  ASDN::MutexLocker l(_lock);
  return _defaultImage;
}

- (void)setDelegate:(id<ASNetworkImageNodeDelegate>)delegate
{
  ASDN::MutexLocker l(_lock);
  _delegate = delegate;
}

- (id<ASNetworkImageNodeDelegate>)delegate
{
  ASDN::MutexLocker l(_lock);
  return _delegate;
}

- (void)displayWillStart
{
  [super displayWillStart];

  [self fetchData];
}

- (void)clearFetchedData
{
  [super clearFetchedData];

  {
    ASDN::MutexLocker l(_lock);

    [self _cancelImageDownload];
    self.image = _defaultImage;
    _imageLoaded = NO;
  }
}

- (void)fetchData
{
  [super fetchData];
  
  {
    ASDN::MutexLocker l(_lock);
    [self _lazilyLoadImageIfNecessary];
  }
}

#pragma mark - Private methods -- only call with lock.

- (void)_cancelImageDownload
{
  if (!_imageDownload) {
    return;
  }

  [_downloader cancelImageDownloadForIdentifier:_imageDownload];
  _imageDownload = nil;

  _cacheUUID = nil;
}

- (void)_downloadImageWithCompletion:(void (^)(CGImageRef))finished
{
  _imageDownload = [_downloader downloadImageWithURL:_URL
                                       callbackQueue:dispatch_get_main_queue()
                               downloadProgressBlock:NULL
                                          completion:^(CGImageRef responseImage, NSError *error) {
                                            if (finished != NULL) {
                                              finished(responseImage);
                                            }
                                          }];
}

- (void)_lazilyLoadImageIfNecessary
{
  if (!_imageLoaded && _URL != nil && _imageDownload == nil) {
    if (_URL.isFileURL) {
      {
        ASDN::MutexLocker l(_lock);

        dispatch_async(dispatch_get_main_queue(), ^{
          if (self.shouldCacheImage) {
            self.image = [UIImage imageNamed:_URL.path.lastPathComponent];
          } else {
            // First try to load the path directly, for efficiency assuming a developer who
            // doesn't want caching is trying to be as minimal as possible.
            self.image = [UIImage imageWithContentsOfFile:_URL.path];
            if (!self.image) {
              // If we couldn't find it, execute an -imageNamed:-like search so we can find resources even if the
              // extension is not provided in the path.  This allows the same path to work regardless of shouldCacheImage.
              NSString *filename = [[NSBundle mainBundle] pathForResource:_URL.path.lastPathComponent ofType:nil];
              if (filename) {
                self.image = [UIImage imageWithContentsOfFile:filename];
              }
            }
          }
          
          _imageLoaded = YES;
          [_delegate imageNode:self didLoadImage:self.image];
        });
      }
    } else {
      __weak __typeof__(self) weakSelf = self;
      void (^finished)(CGImageRef) = ^(CGImageRef responseImage) {
        __typeof__(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
          return;
        }

        {
          ASDN::MutexLocker l(strongSelf->_lock);

          if (responseImage != NULL) {
            strongSelf->_imageLoaded = YES;
            strongSelf.image = [UIImage imageWithCGImage:responseImage];
          }

          strongSelf->_imageDownload = nil;

          strongSelf->_cacheUUID = nil;
        }

        if (responseImage != NULL) {
          [strongSelf->_delegate imageNode:strongSelf didLoadImage:strongSelf.image];
        }
      };

      if (_cache != nil) {
        NSUUID *cacheUUID = [NSUUID UUID];
        _cacheUUID = cacheUUID;

        void (^cacheCompletion)(CGImageRef) = ^(CGImageRef image) {
          // If the cache UUID changed, that means this request was cancelled.
          if (![_cacheUUID isEqual:cacheUUID]) {
            return;
          }

          if (image == NULL && _downloader != nil) {
            [self _downloadImageWithCompletion:finished];
          } else {
            finished(image);
          }
        };

        [_cache fetchCachedImageWithURL:_URL
                          callbackQueue:dispatch_get_main_queue()
                             completion:cacheCompletion];
      } else {
        [self _downloadImageWithCompletion:finished];
      }
    }
  }
}

#pragma mark - ASDisplayNode+Subclasses

- (void)asyncdisplaykit_asyncTransactionContainerStateDidChange
{
  if (self.asyncdisplaykit_asyncTransactionContainerState == ASAsyncTransactionContainerStateNoTransactions) {
    if (self.layer.contents != nil && [self.delegate respondsToSelector:@selector(imageNodeDidFinishDecoding:)]) {
      [self.delegate imageNodeDidFinishDecoding:self];
    }
  }
}

@end
