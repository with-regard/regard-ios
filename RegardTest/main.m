//
//  main.m
//

#import <UIKit/UIKit.h>

#import "RGAppDelegate.h"
#import "Regard.h"

int main(int argc, char * argv[])
{
    @autoreleasepool {
        [Regard optInByDefault];
        [Regard track: @"start" withProperties: @{ @"Test": @"Test" }];
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([RGAppDelegate class]));
    }
}
