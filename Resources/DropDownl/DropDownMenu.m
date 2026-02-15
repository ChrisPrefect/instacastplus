//
//  DropDownMenu.m
//  Instacast
//
//  Created by Devendra Kamal on 02.08.2024.
//


#import "DropDownMenu.h"

@interface DropDownMenu ()

{
    IBOutlet UITableView *dropDownTable;
    IBOutlet UILabel *titleLbl;
    IBOutlet UIView *mainVieww;
    IBOutlet UILabel *seperatorLbl;
    IBOutlet UIImageView *notchImageView;
    
    NSArray *myList;
}

@end

@implementation DropDownMenu

- (void)viewDidLoad {
    [super viewDidLoad];
    
    mainVieww.layer.borderWidth = 1.0;
    mainVieww.layer.cornerRadius = 10;
    mainVieww.layer.borderColor = [UIColor grayColor].CGColor;
    mainVieww.clipsToBounds = true;
    
    if ([UIScreen mainScreen].traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
        mainVieww.backgroundColor = [UIColor blackColor];
        titleLbl.textColor = [UIColor whiteColor];
        seperatorLbl.backgroundColor = [UIColor whiteColor];
        [notchImageView setImage:[UIImage imageNamed:@"dark_dd_ic.png"]];
    } else {
        mainVieww.backgroundColor = [UIColor whiteColor];
        titleLbl.textColor = [UIColor blackColor];
        seperatorLbl.backgroundColor = [UIColor blackColor];
        [notchImageView setImage:[UIImage imageNamed:@"light_dd_ic.png"]];
    }
    myList = [[NSArray alloc]initWithObjects:@"Off".ls, @"5 Minutes".ls, @"10 Minutes".ls, @"15 Minutes".ls, @"20 Minutes".ls, @"30 Minutes".ls, @"60 Minutes".ls, nil];
    NSInteger sleepTimer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
    if (sleepTimer == PlaybackStopTimeNoValue)
    {
        titleLbl.text = @"Intelligent Sleep timer (off)";
    }
    else
    {
        titleLbl.text = @"Intelligent Sleep timer (on)";
    }
    // Do any additional setup after loading the view.
}

- (void)realodDropDownView {
    // code to load data from network, and refresh the interface
    [dropDownTable reloadData];
    NSInteger sleepTimer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
    if (sleepTimer == PlaybackStopTimeNoValue)
    {
        titleLbl.text = @"Intelligent Sleep timer (off)";
    }
    else
    {
        titleLbl.text = @"Intelligent Sleep timer (on)";
    }
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void) viewWillAppear:(BOOL)animated
{
  
}

/*
#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
}
*/

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return [myList count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *CellIdentifier = @"cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle: UITableViewCellStyleDefault reuseIdentifier: CellIdentifier];
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    cell.textLabel.text = [myList objectAtIndex:indexPath.row];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.layoutMargins = UIEdgeInsetsMake(0, 10, 0, 10);
    
    NSInteger sleepTimer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
    NSDictionary* sleepTimerValues = @{ @(PlaybackStopTimeNoValue) : @"Off".ls,
                                        @(PlaybackStopTime5min) : @"5 Minutes".ls,
                                        @(PlaybackStopTime10min) : @"10 Minutes".ls,
                                        @(PlaybackStopTime15min) : @"15 Minutes".ls,
                                        @(PlaybackStopTime20min) : @"20 Minutes".ls,
                                        @(PlaybackStopTime30min) : @"30 Minutes".ls,
                                        @(PlaybackStopTime60min) : @"60 Minutes".ls };
    
    NSString* valueString = sleepTimerValues[@(sleepTimer)];
    
    if ([[myList objectAtIndex:indexPath.row] isEqualToString:valueString])
    {
        cell.accessoryType=UITableViewCellAccessoryCheckmark;
        cell.layoutMargins = UIEdgeInsetsMake(0, 40, 0, 10);
    }
    else if ([[myList objectAtIndex:indexPath.row] isEqualToString:valueString])
    {
        cell.accessoryType=UITableViewCellAccessoryCheckmark;
        cell.layoutMargins = UIEdgeInsetsMake(0, 40, 0, 10);
    }
    else if ([[myList objectAtIndex:indexPath.row] isEqualToString:valueString])
    {
        cell.accessoryType=UITableViewCellAccessoryCheckmark;
        cell.layoutMargins = UIEdgeInsetsMake(0, 40, 0, 10);
    }
    else if ([[myList objectAtIndex:indexPath.row] isEqualToString:valueString])
    {
        cell.accessoryType=UITableViewCellAccessoryCheckmark;
        cell.layoutMargins = UIEdgeInsetsMake(0, 40, 0, 10);
    }
    else if ([[myList objectAtIndex:indexPath.row] isEqualToString:valueString])
    {
        cell.accessoryType=UITableViewCellAccessoryCheckmark;
        cell.layoutMargins = UIEdgeInsetsMake(0, 40, 0, 10);
    }
    else if ([[myList objectAtIndex:indexPath.row] isEqualToString:valueString])
    {
        cell.accessoryType=UITableViewCellAccessoryCheckmark;
        cell.layoutMargins = UIEdgeInsetsMake(0, 40, 0, 10);
    }
    else if ([[myList objectAtIndex:indexPath.row] isEqualToString:valueString])
    {
        cell.accessoryType=UITableViewCellAccessoryCheckmark;
        cell.layoutMargins = UIEdgeInsetsMake(0, 40, 0, 10);
    }
    
    if ([UIScreen mainScreen].traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
        cell.textLabel.textColor = [UIColor whiteColor];
        if ([indexPath row] % 2 == 0)
        {
            cell.backgroundColor = [UIColor blackColor];
        }
        else
        {
            cell.backgroundColor = [UIColor lightGrayColor];
        }
    } else {
        cell.textLabel.textColor = [UIColor blackColor];
        if ([indexPath row] % 2 == 0)
        {
            cell.backgroundColor = [UIColor whiteColor];
        }
        else
        {
            cell.backgroundColor = [UIColor lightGrayColor];
        }
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *dictionary = [NSDictionary dictionaryWithObject:[myList objectAtIndex:indexPath.row] forKey:@"item"];
    
    [tableView deselectRowAtIndexPath:indexPath animated:YES]; 
    [[NSNotificationCenter defaultCenter] postNotificationName:@"selectedListItem" object:self userInfo:dictionary];
}


@end
