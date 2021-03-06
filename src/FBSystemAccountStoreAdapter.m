/*
 * Copyright 2010-present Facebook.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "FBSystemAccountStoreAdapter.h"
#import "FBError.h"
#import "FBUtility.h"
#import "FBLogger.h"
#import "FBSettings.h"
#import "FBErrorUtility+Internal.h"
#import "FBAccessTokenData.h"

@interface FBSystemAccountStoreAdapter() {
    BOOL _forceBlockingRenew;
}

@property (retain, nonatomic, readonly) ACAccountStore *accountStore;
@property (retain, nonatomic, readonly) ACAccountType *accountTypeFB;

@end

static NSString *const FBForceBlockingRenewKey = @"com.facebook.sdk:ForceBlockingRenewKey";
static FBSystemAccountStoreAdapter* _singletonInstance = nil;

@implementation FBSystemAccountStoreAdapter

@synthesize accountStore = _accountStore;
@synthesize accountTypeFB = _accountTypeFB;

- (id)init {
    self = [super init];
    if (self) {
        _forceBlockingRenew = [[NSUserDefaults standardUserDefaults] boolForKey:FBForceBlockingRenewKey];
        _accountStore = [[ACAccountStore alloc] init];
        _accountTypeFB = [[_accountStore accountTypeWithAccountTypeIdentifier:@"com.apple.facebook"] retain];
    }
    return self;
}

- (void) dealloc {
    [_accountStore release];
    [_accountTypeFB release];
    [super dealloc];
}

#pragma mark - Properties
- (BOOL) forceBlockingRenew {
    return _forceBlockingRenew;
}

- (void) setForceBlockingRenew:(BOOL)forceBlockingRenew{
    if (_forceBlockingRenew!= forceBlockingRenew){
        _forceBlockingRenew = forceBlockingRenew;
        NSUserDefaults* userDefaults = [NSUserDefaults standardUserDefaults];
        [userDefaults setBool:forceBlockingRenew forKey:FBForceBlockingRenewKey];
        [userDefaults synchronize];
    }
}

+ (FBSystemAccountStoreAdapter*) sharedInstance {
    if (_singletonInstance == nil) {
        static dispatch_once_t onceToken;
        
        dispatch_once(&onceToken, ^{
            _singletonInstance = [[FBSystemAccountStoreAdapter alloc] init];
        });
    }
    
    return _singletonInstance;
}

+ (void) setSharedInstance:(FBSystemAccountStoreAdapter *) instance {
    if (instance != _singletonInstance){
        [_singletonInstance release];
         _singletonInstance = [instance retain];
    }
}

- (BOOL) canRequestAccessWithoutUI {
    if (self.accountTypeFB && self.accountTypeFB.accessGranted) {
        NSArray *fbAccounts = [self.accountStore accountsWithAccountType:self.accountTypeFB];
        if (fbAccounts.count > 0) {
            id account = [fbAccounts objectAtIndex:0];
            id credential = [account credential];
        
            return [credential oauthToken].length > 0;
        }
    }
    return NO;
}

#pragma  mark - Public properties and methods

- (void)requestAccessToFacebookAccountStore:(FBSession *)session
                                    handler:(FBRequestAccessToAccountsHandler)handler {
    return [self requestAccessToFacebookAccountStore:session.accessTokenData.permissions
                                     defaultAudience:session.lastRequestedSystemAudience
                                       isReauthorize:NO
                                               appID:session.appID
                                             session:session
                                             handler:handler];
}

- (void)requestAccessToFacebookAccountStore:(NSArray *)permissions
                            defaultAudience:(FBSessionDefaultAudience)defaultAudience
                              isReauthorize:(BOOL)isReauthorize
                                      appID:(NSString *)appID
                                    session:(FBSession *)session
                                    handler:(FBRequestAccessToAccountsHandler)handler {
    if (appID == nil) {
        @throw [NSException exceptionWithName:NSInvalidArgumentException
                                                         reason:@"appID cannot be nil"
                                                       userInfo:nil];
    }

    // app may be asking for nothing, but we will always have an array here
    NSArray *permissionsToUse = permissions ? permissions : [NSArray array];
    if ([FBUtility areAllPermissionsReadPermissions:permissions]) {
        // If we have only read permissions being requested, ensure that basic info
        //  is among the permissions requested.
        permissionsToUse = [FBUtility addBasicInfoPermission:permissionsToUse];
    }
    
    NSString *audience;
    switch (defaultAudience) {
        case FBSessionDefaultAudienceOnlyMe:
            audience = ACFacebookAudienceOnlyMe;
            break;
        case FBSessionDefaultAudienceFriends:
            audience = ACFacebookAudienceFriends;
            break;
        case FBSessionDefaultAudienceEveryone:
            audience = ACFacebookAudienceEveryone;
            break;
        default:
            audience = nil;
    }
    
    // no publish_* permissions are permitted with a nil audience
    if (!audience && isReauthorize) {
        for (NSString *p in permissions) {
            if ([p hasPrefix:@"publish"]) {
                [[NSException exceptionWithName:FBInvalidOperationException
                                         reason:@"FBSession: One or more publish permission was requested "
                  @"without specifying an audience; use FBSessionDefaultAudienceJustMe, "
                  @"FBSessionDefaultAudienceFriends, or FBSessionDefaultAudienceEveryone"
                                       userInfo:nil]
                 raise];
            }
        }
    }
    
    // construct access options
    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
                             appID, ACFacebookAppIdKey,
                             permissionsToUse, ACFacebookPermissionsKey,
                             audience, ACFacebookAudienceKey, // must end on this key/value due to audience possibly being nil
                             nil];
    
    //wrap the request call into a separate block to help with possibly block chaining below.
    void(^requestAccessBlock)(void) = ^{
        if (!self.accountTypeFB) {
            if (handler) {
                handler(nil, [session errorLoginFailedWithReason:FBErrorLoginFailedReasonSystemError
                                                       errorCode:nil
                                                      innerError:nil]);
            }
            return;
        }
        // we will attempt an iOS integrated facebook login
        [self.accountStore
         requestAccessToAccountsWithType:self.accountTypeFB
         options:options
         completion:^(BOOL granted, NSError *error) {
             if (!(granted ||
                   error.code != ACErrorPermissionDenied ||
                   [error.description rangeOfString:@"remote_app_id does not match stored id"].location == NSNotFound)) {

                 [FBLogger singleShotLogEntry:FBLoggingBehaviorDeveloperErrors formatString:
                              @"System authorization failed:'%@'. This may be caused by a mismatch between"
                              @" the bundle identifier and your app configuration on the server"
                              @" at developers.facebook.com/apps.",
                  error.localizedDescription];
             }
             
             // requestAccessToAccountsWithType:options:completion: completes on an
             // arbitrary thread; let's process this back on our main thread
             dispatch_async( dispatch_get_main_queue(), ^{
                 NSError* accountStoreError = error;
                 NSString *oauthToken = nil;
                 if (granted) {
                     NSArray *fbAccounts = [self.accountStore accountsWithAccountType:self.accountTypeFB];
                     id account = [fbAccounts objectAtIndex:0];
                     id credential = [account credential];
                     
                     oauthToken = [credential oauthToken];
                 }
                 
                 if (!accountStoreError && !oauthToken){
                     // This means iOS did not give an error nor granted. In order to
                     // surface this to users, stuff in our own error that can be inspected.
                     accountStoreError = [session errorLoginFailedWithReason:FBErrorLoginFailedReasonSystemDisallowedWithoutErrorValue
                                                                   errorCode:nil
                                                                  innerError:nil];
                 }
                 handler(oauthToken, accountStoreError);
             });
         }];
    };
    
    if (self.forceBlockingRenew
        && [self.accountStore accountsWithAccountType:self.accountTypeFB].count > 0) {
        // If the force renew flag is set and an iOS FB account is still set,
        // chain the requestAccessBlock to a successful renew result
        [self renewSystemAuthorization:^(ACAccountCredentialRenewResult result, NSError *error) {
            if (result == ACAccountCredentialRenewResultRenewed) {
                self.forceBlockingRenew = NO;
                requestAccessBlock();
            } else if (handler) {
                // Otherwise, invoke the caller's handler back on the main thread with an
                // error that will trigger the password change user message.
                dispatch_async(dispatch_get_main_queue(), ^{
                    handler(nil, [FBErrorUtility fberrorForSystemPasswordChange:error]);
                });
            }
        }];
    } else {
        // Otherwise go ahead and invoke normal request.
        requestAccessBlock();
    }
}

- (void)renewSystemAuthorization:(void( ^ )(ACAccountCredentialRenewResult, NSError* )) handler {
    // if the slider has been set to off, renew calls to iOS simply hang, so we must
    // preemptively check for that condition.
    if (self.accountStore && self.accountTypeFB && self.accountTypeFB.accessGranted) {
        NSArray *fbAccounts = [self.accountStore accountsWithAccountType:self.accountTypeFB];
        id account;
        if (fbAccounts && [fbAccounts count] > 0 &&
            (account = [fbAccounts objectAtIndex:0])){
            
            [self.accountStore renewCredentialsForAccount:account completion:^(ACAccountCredentialRenewResult renewResult, NSError *error) {
                if (error){
                    [FBLogger singleShotLogEntry:FBLoggingBehaviorAccessTokens
                                        logEntry:[NSString stringWithFormat:@"renewCredentialsForAccount result:%d, error: %@",
                                                  renewResult,
                                                  error]];
                }
                if (handler) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        handler(renewResult, error);
                    });
                }
            }];
            return;
        }
    }
    
    if (handler) {
        // If there is a handler and we didn't return earlier (i.e, no renew call), determine an appropriate error to surface.
        NSError *error;
        if (self.accountTypeFB && !self.accountTypeFB.accessGranted) {
            error = [[NSError errorWithDomain:FacebookSDKDomain
                                                 code:FBErrorSystemAPI
                                             userInfo:@{ NSLocalizedDescriptionKey : @"Access has not been granted to the Facebook account. Verify device settings."}]
                     retain];

        } else {
            error = [[NSError errorWithDomain:FacebookSDKDomain
                                        code:FBErrorSystemAPI
                                    userInfo:@{ NSLocalizedDescriptionKey : @"The Facebook account has not been configured on the device."}]
                     retain];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            handler(ACAccountCredentialRenewResultRejected, error);
            [error release];
        });
    }
}

@end
