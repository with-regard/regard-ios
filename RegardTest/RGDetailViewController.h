//
//  RGDetailViewController.h
//

#import <UIKit/UIKit.h>

@interface RGDetailViewController : UIViewController <UISplitViewControllerDelegate>

@property (strong, nonatomic) id detailItem;

@property (weak, nonatomic) IBOutlet UILabel *detailDescriptionLabel;
@end
