#import "ImageLoader.h"
#import "Diag.h"

#define MAX_IMAGE_SLOTS 96
#define IMAGE_TIMEOUT   12.0

typedef struct {
    NSString         *url;
    UIImage          *image;
    NSMutableData    *buffer;
    NSURLConnection  *connection;
    int               failed;
} ImageSlot;

static ImageSlot sSlots[MAX_IMAGE_SLOTS];
static int       sUsed = 0;
static id        sDelegate = nil;
static void    (*sUpdateCallback)(void) = 0;

static int FindSlotByURL(NSString *url)
{
    int i;
    if (!url) return -1;
    for (i = 0; i < sUsed; i++) {
        if (sSlots[i].url && [sSlots[i].url isEqualToString:url]) return i;
    }
    return -1;
}

static int FindSlotByConnection(NSURLConnection *connection)
{
    int i;
    for (i = 0; i < sUsed; i++) {
        if (sSlots[i].connection && sSlots[i].connection == connection) return i;
    }
    return -1;
}

static void ClearSlot(int i)
{
    if (sSlots[i].connection) {
        [sSlots[i].connection cancel];
        [sSlots[i].connection release];
        sSlots[i].connection = nil;
    }
    if (sSlots[i].buffer)    { [sSlots[i].buffer release];    sSlots[i].buffer = nil; }
    if (sSlots[i].image)     { [sSlots[i].image release];     sSlots[i].image = nil; }
    if (sSlots[i].url)       { [sSlots[i].url release];       sSlots[i].url = nil; }
    sSlots[i].failed = 0;
}

static void FinishSlot(int i, BOOL ok)
{
    if (sSlots[i].buffer) {
        if (ok) {
            UIImage *img = [UIImage imageWithData:sSlots[i].buffer];
            if (img) { sSlots[i].image = [img retain]; diag("ImageLoader: image decoded ok"); }
            else     { sSlots[i].failed = 1; diag("ImageLoader: image decode failed"); }
        } else {
            sSlots[i].failed = 1;
            diag("ImageLoader: request failed");
        }
        [sSlots[i].buffer release];
        sSlots[i].buffer = nil;
    } else {
        sSlots[i].failed = 1;
    }
    if (sSlots[i].connection) {
        [sSlots[i].connection release];
        sSlots[i].connection = nil;
    }
    if (sUpdateCallback) sUpdateCallback();
}

@interface ImageLoaderDelegate : NSObject @end

@implementation ImageLoaderDelegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    (void)connection;
    (void)response;
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    int i = FindSlotByConnection(connection);
    if (i >= 0 && sSlots[i].buffer && data) [sSlots[i].buffer appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    int i = FindSlotByConnection(connection);
    if (i >= 0) FinishSlot(i, YES);
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(id)error
{
    int i = FindSlotByConnection(connection);
    (void)error;
    if (i >= 0) FinishSlot(i, NO);
}

@end

void ImageLoaderSetUpdateCallback(void (*callback)(void))
{
    sUpdateCallback = callback;
}

UIImage *ImageLoaderCachedImage(NSString *url)
{
    int i = FindSlotByURL(url);
    if (i >= 0 && sSlots[i].image) return sSlots[i].image;
    return nil;
}

void ImageLoaderRequest(NSString *url)
{
    NSURL *nsurl;
    NSURLRequest *request;
    NSURLConnection *connection;
    int i;

    if (!url || [url length] == 0) return;
    if (FindSlotByURL(url) >= 0) return;     /* 已缓存 / 下载中 / 已失败，均不重复请求 */

    if (sUsed >= MAX_IMAGE_SLOTS) {
        /* URL 带 Expires 签名，缓存不宜无限增长；满了就整体清空重新下载 */
        ImageLoaderReset();
    }
    if (!sDelegate) sDelegate = [[ImageLoaderDelegate alloc] init];

    nsurl = [NSURL URLWithString:url];
    if (!nsurl) return;
    request = [NSURLRequest requestWithURL:nsurl
                               cachePolicy:0
                           timeoutInterval:IMAGE_TIMEOUT];
    /* startImmediately:NO —— 先把 connection 存进槽位再 start，
       保证 delegate 回调一定能通过 connection 指针反查到对应槽位。 */
    connection = [[NSURLConnection alloc] initWithRequest:request
                                                 delegate:sDelegate
                                        startImmediately:NO];
    if (!connection) return;

    i = sUsed;
    sSlots[i].url        = [url retain];
    sSlots[i].image      = nil;
    sSlots[i].buffer     = [[NSMutableData alloc] init];
    sSlots[i].connection = connection;
    sSlots[i].failed     = 0;
    sUsed = i + 1;
    [connection start];
}

void ImageLoaderReset(void)
{
    int i;
    for (i = 0; i < sUsed; i++) ClearSlot(i);
    sUsed = 0;
}
