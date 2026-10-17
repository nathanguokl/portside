#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>

// Finder's icvp background field uses a classic AliasRecord. Build a fresh store;
// never copy Finder's stale/free blocks, security bookmarks, or host-image aliases.
static void require(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"DMG layout" reason:message userInfo:nil];
}
static NSData *u32(uint32_t value) {
    value = CFSwapInt32HostToBig(value);
    return [NSData dataWithBytes:&value length:4];
}
static uint16_t read16(const uint8_t *bytes) { return (uint16_t)(bytes[0] << 8 | bytes[1]); }
static NSData *plist(NSDictionary *value) {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    require(data != nil, error.localizedDescription);
    return data;
}
static NSData *record(NSString *name, const char *code, NSData *value) {
    NSMutableData *data = [NSMutableData dataWithData:u32((uint32_t)name.length)];
    [data appendData:[name dataUsingEncoding:NSUTF16BigEndianStringEncoding]];
    [data appendBytes:code length:4]; [data appendBytes:"blob" length:4];
    [data appendData:u32((uint32_t)value.length)]; [data appendData:value];
    return data;
}
static void verifyAlias(NSData *alias, NSURL *root) {
    CFDataRef converted = CFURLCreateBookmarkDataFromAliasRecord(NULL, (__bridge CFDataRef)alias);
    require(converted != NULL, @"Could not interpret the image-relative background alias.");
    NSError *error = nil; BOOL stale = NO;
    NSURL *resolved = [NSURL URLByResolvingBookmarkData:CFBridgingRelease(converted)
                  options:NSURLBookmarkResolutionWithoutUI | NSURLBookmarkResolutionWithoutMounting
                  relativeToURL:root bookmarkDataIsStale:&stale error:&error];
    require([resolved.URLByStandardizingPath.path isEqualToString:[root.path stringByAppendingPathComponent:@".background/background.png"]],
            error.localizedDescription ?: @"Background alias did not resolve inside this mounted image.");
}
static NSData *backgroundAlias(NSURL *root) {
    NSURL *background = [root URLByAppendingPathComponent:@".background/background.png"];
    require([background.URLByResolvingSymlinksInPath.path isEqualToString:background.path], @"The image background must not be a symbolic link.");
    FSRef reference; AliasHandle handle = NULL;
    require(FSPathMakeRef((const UInt8 *)background.fileSystemRepresentation, &reference, NULL) == noErr, @"The image background is missing.");
    require(FSNewAliasMinimal(&reference, &handle) == noErr && handle != NULL, @"Could not create the image background alias.");
    NSData *native = [NSData dataWithBytes:*handle length:(NSUInteger)GetAliasSizeFromPtr(*handle)];
    DisposeHandle((Handle)handle);
    const uint8_t *bytes = native.bytes;
    require(native.length >= 154 && read16(bytes + 6) == 2, @"Unexpected native AliasRecord format.");
    NSMutableData *clean = [NSMutableData dataWithBytes:bytes length:150];
    BOOL relativePath = NO;
    for (NSUInteger offset = 150; offset + 4 <= native.length;) {
        uint16_t tag = read16(bytes + offset), size = read16(bytes + offset + 2);
        NSUInteger length = 4 + size + (size & 1);
        require(offset + length <= native.length, @"Truncated native AliasRecord.");
        if (tag == 0xffff) break;
        // Only target-volume names, IDs, dates, and the volume-relative path.
        // In particular exclude tag 19 (mount path), tag 20 (recursive alias to
        // the backing .dmg on the developer's disk), and all unknown extensions.
        if (tag <= 2 || (tag >= 14 && tag <= 18)) {
            if (tag == 18) {
                NSData *path = [NSData dataWithBytes:bytes + offset + 4 length:size];
                NSString *text = [[NSString alloc] initWithData:path encoding:NSUTF8StringEncoding];
                relativePath = [text isEqualToString:@"/.background/background.png"] || [text isEqualToString:@".background/background.png"];
                require(relativePath, @"The alias contains an unexpected background path.");
            }
            [clean appendBytes:bytes + offset length:length];
        }
        offset += length;
    }
    require(relativePath, @"The native alias has no image-relative background path.");
    const uint8_t end[] = {255, 255, 0, 0}; [clean appendBytes:end length:4];
    require(clean.length <= UINT16_MAX, @"Background alias is too large.");
    uint16_t length = CFSwapInt16HostToBig((uint16_t)clean.length);
    [clean replaceBytesInRange:NSMakeRange(4, 2) withBytes:&length];
    verifyAlias(clean, root);
    return clean;
}
static void writeAt(NSMutableData *data, NSData *value, NSUInteger offset) {
    require(offset + value.length <= data.length, @"Finder layout exceeded its allocated block.");
    [data replaceBytesInRange:NSMakeRange(offset, value.length) withBytes:value.bytes];
}
static NSData *layout(NSData *alias) {
    NSDictionary *window = @{@"ShowStatusBar":@NO, @"ShowToolbar":@NO, @"ShowTabView":@NO,
        @"ContainerShowSidebar":@NO, @"ShowSidebar":@NO, @"WindowBounds":@"{{220, 160}, {640, 428}}"};
    NSDictionary *icons = @{@"backgroundType":@2, @"backgroundImageAlias":alias,
        @"backgroundColorRed":@1.0, @"backgroundColorGreen":@1.0, @"backgroundColorBlue":@1.0,
        @"iconSize":@128.0, @"textSize":@14.0, @"gridOffsetX":@0.0, @"gridOffsetY":@0.0,
        @"gridSpacing":@100.0, @"showItemInfo":@NO, @"viewOptionsVersion":@1,
        @"arrangeBy":@"none", @"labelOnBottom":@YES, @"showIconPreview":@YES};
    NSMutableData *version = [NSMutableData dataWithData:u32(1)];
    [version appendBytes:"\0.vSrnlong" length:10]; [version appendData:u32(1)];
    NSMutableArray<NSData *> *records = [NSMutableArray arrayWithArray:@[
        record(@".", "bwsp", plist(window)), record(@".", "icvp", plist(icons)), version]];
    for (NSString *name in @[@"Applications", @"Portside.app"]) {
        NSMutableData *location = [NSMutableData dataWithData:u32([name isEqualToString:@"Applications"] ? 485 : 155)];
        [location appendData:u32(220)]; const uint8_t end[] = {255,255,255,255,255,255,0,0};
        [location appendBytes:end length:8]; [records addObject:record(name, "Iloc", location)];
    }
    NSMutableData *node = [NSMutableData dataWithData:u32(0)]; [node appendData:u32((uint32_t)records.count)];
    for (NSData *value in records) [node appendData:value];
    require(node.length <= 4096, @"Finder layout exceeded its single leaf page.");
    // All bytes start zeroed: allocator block 0 at 8192, metadata block 1 at
    // 64, and leaf block 2 at 4096. File offsets exclude the 4-byte signature.
    NSMutableData *data = [NSMutableData dataWithLength:4 + 8192 + 2048];
    NSMutableData *header = [NSMutableData dataWithData:u32(1)]; [header appendBytes:"Bud1" length:4];
    for (NSNumber *number in @[@8192,@2048,@8192,@0x100c,@0,@0,@0]) [header appendData:u32(number.unsignedIntValue)];
    writeAt(data, header, 0);
    NSMutableData *master = [NSMutableData data];
    for (NSNumber *number in @[@2,@0,@(records.count),@1,@4096]) [master appendData:u32(number.unsignedIntValue)];
    writeAt(data, master, 4 + 64); writeAt(data, node, 4 + 4096);
    NSMutableData *allocator = [NSMutableData dataWithData:u32(3)]; [allocator appendData:u32(0)];
    for (NSNumber *number in @[@(8192 | 11),@(64 | 5),@(4096 | 12)]) [allocator appendData:u32(number.unsignedIntValue)];
    [allocator increaseLengthBy:(256 - 3) * 4]; [allocator appendData:u32(1)];
    [allocator appendBytes:"\4DSDB" length:5]; [allocator appendData:u32(1)];
    for (unsigned power = 0; power < 32; power++) {
        NSArray<NSNumber *> *offsets = @[];
        if (power == 5) offsets = @[@32,@96];
        else if (power == 11) offsets = @[@2048,@10240];
        else if (power == 12) offsets = @[@12288];
        else if ((power >= 7 && power <= 10) || (power >= 14 && power <= 30)) offsets = @[@(1u << power)];
        [allocator appendData:u32((uint32_t)offsets.count)];
        for (NSNumber *number in offsets) [allocator appendData:u32(number.unsignedIntValue)];
    }
    require(allocator.length <= 2048, @"Finder allocator metadata exceeded its block.");
    writeAt(data, allocator, 4 + 8192);
    return data;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool { @try {
        require(argc == 2, @"Usage: make-dmg-layout /Volumes/Portside");
        NSURL *root = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]] isDirectory:YES].URLByStandardizingPath;
        NSURL *volume = nil; [root getResourceValue:&volume forKey:NSURLVolumeURLKey error:nil];
        require([root.path hasPrefix:@"/Volumes/"] && [volume.path isEqualToString:root.path], @"Pass the mounted image volume root under /Volumes.");
        NSData *data = layout(backgroundAlias(root));
        NSURL *destination = [root URLByAppendingPathComponent:@".DS_Store"];
        NSNumber *link = nil; [destination getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
        require(!link.boolValue, @"Refusing a symbolic-link Finder layout destination.");
        NSError *error = nil; require([data writeToURL:destination options:NSDataWritingAtomic error:&error], error.localizedDescription);
        puts("Generated fresh Finder layout with an image-relative background alias.");
        return 0;
    } @catch (NSException *error) {
        fprintf(stderr, "DMG layout: %s\n", error.reason.UTF8String); return 1;
    } }
}
