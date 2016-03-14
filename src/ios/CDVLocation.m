/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "CDVLocation.h"

#pragma mark Constants

#define kPGLocationErrorDomain @"kPGLocationErrorDomain"
#define kPGLocationDesiredAccuracyKey @"desiredAccuracy"
#define kPGLocationForcePromptKey @"forcePrompt"
#define kPGLocationDistanceFilterKey @"distanceFilter"
#define kPGLocationFrequencyKey @"frequency"

#pragma mark -
#pragma mark Categories

@implementation CDVLocationData

@synthesize locationStatus, locationInfo, locationCallbacks, watchCallbacks;
- (CDVLocationData*)init
{
    self = (CDVLocationData*)[super init];
    if (self) {
        self.locationInfo = nil;
        self.locationCallbacks = nil;
        self.watchCallbacks = nil;
    }
    return self;
}

@end

#pragma mark -
#pragma mark CDVLocation

@implementation CDVLocation

@synthesize locationManager, locationData;

- (void)pluginInitialize
{
    self.locationManager = [[CLLocationManager alloc] init];
    self.locationManager.delegate = self; // Tells the location manager to send updates to this object
    __locationStarted = NO;
    __highAccuracyEnabled = NO;
    self.locationData = nil;
}

- (BOOL)isAuthorized
{
    BOOL authorizationStatusClassPropertyAvailable = [CLLocationManager respondsToSelector:@selector(authorizationStatus)]; // iOS 4.2+

    if (authorizationStatusClassPropertyAvailable) {
        NSUInteger authStatus = [CLLocationManager authorizationStatus];
#ifdef __IPHONE_8_0
        if ([self.locationManager respondsToSelector:@selector(requestWhenInUseAuthorization)]) {  //iOS 8.0+
            return (authStatus == kCLAuthorizationStatusAuthorizedWhenInUse) || (authStatus == kCLAuthorizationStatusAuthorizedAlways) || (authStatus == kCLAuthorizationStatusNotDetermined);
        }
#endif
        return (authStatus == kCLAuthorizationStatusAuthorized) || (authStatus == kCLAuthorizationStatusNotDetermined);
    }

    // by default, assume YES (for iOS < 4.2)
    return YES;
}

- (BOOL)isLocationServicesEnabled
{
    BOOL locationServicesEnabledInstancePropertyAvailable = [self.locationManager respondsToSelector:@selector(locationServicesEnabled)]; // iOS 3.x
    BOOL locationServicesEnabledClassPropertyAvailable = [CLLocationManager respondsToSelector:@selector(locationServicesEnabled)]; // iOS 4.x

    if (locationServicesEnabledClassPropertyAvailable) { // iOS 4.x
        return [CLLocationManager locationServicesEnabled];
    } else if (locationServicesEnabledInstancePropertyAvailable) { // iOS 2.x, iOS 3.x
        return [(id)self.locationManager locationServicesEnabled];
    } else {
        return NO;
    }
}

- (void)startLocation:(BOOL)enableHighAccuracy
{
    if (![self isLocationServicesEnabled]) {
        [self returnLocationError:PERMISSIONDENIED withMessage:@"Location services are not enabled."];
        return;
    }
    if (![self isAuthorized]) {
        NSString* message = nil;
        BOOL authStatusAvailable = [CLLocationManager respondsToSelector:@selector(authorizationStatus)]; // iOS 4.2+
        if (authStatusAvailable) {
            NSUInteger code = [CLLocationManager authorizationStatus];
            if (code == kCLAuthorizationStatusNotDetermined) {
                // could return POSITION_UNAVAILABLE but need to coordinate with other platforms
                message = @"User undecided on application's use of location services.";
            } else if (code == kCLAuthorizationStatusRestricted) {
                message = @"Application's use of location services is restricted.";
            }
        }
        // PERMISSIONDENIED is only PositionError that makes sense when authorization denied
        [self returnLocationError:PERMISSIONDENIED withMessage:message];

        return;
    }

#ifdef __IPHONE_8_0
    NSUInteger code = [CLLocationManager authorizationStatus];
    if (code == kCLAuthorizationStatusNotDetermined && ([self.locationManager respondsToSelector:@selector(requestAlwaysAuthorization)] || [self.locationManager respondsToSelector:@selector(requestWhenInUseAuthorization)])) { //iOS8+
        __highAccuracyEnabled = enableHighAccuracy;
        if([[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSLocationWhenInUseUsageDescription"]){
            [self.locationManager requestWhenInUseAuthorization];
        } else if([[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSLocationAlwaysUsageDescription"]) {
            [self.locationManager  requestAlwaysAuthorization];
        } else {
            NSLog(@"[Warning] No NSLocationAlwaysUsageDescription or NSLocationWhenInUseUsageDescription key is defined in the Info.plist file.");
        }
        return;
    }
#endif

    // Tell the location manager to start notifying us of location updates. We
    // first stop, and then start the updating to ensure we get at least one
    // update, even if our location did not change.
    [self.locationManager stopUpdatingLocation];
    [self.locationManager startUpdatingLocation];
    __locationStarted = YES;
    if (enableHighAccuracy) {
        __highAccuracyEnabled = YES;
        // Set distance filter to 5 for a high accuracy. Setting it to "kCLDistanceFilterNone" could provide a
        // higher accuracy, but it's also just spamming the callback with useless reports which drain the battery.
        self.locationManager.distanceFilter = 5;
        // Set desired accuracy to Best.
        self.locationManager.desiredAccuracy = kCLLocationAccuracyBest;
    } else {
        __highAccuracyEnabled = NO;
        self.locationManager.distanceFilter = 10;
        self.locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers;
    }
}

- (void)_stopLocation
{
    if (__locationStarted) {
        if (![self isLocationServicesEnabled]) {
            return;
        }

        [self.locationManager stopUpdatingLocation];
        __locationStarted = NO;
        __highAccuracyEnabled = NO;
    }
}

- (void)locationManager:(CLLocationManager*)manager
    didUpdateToLocation:(CLLocation*)newLocation
           fromLocation:(CLLocation*)oldLocation
{
    CDVLocationData* cData = self.locationData;

    cData.locationInfo = newLocation;
    if (self.locationData.locationCallbacks.count > 0) {
        for (NSString* callbackId in self.locationData.locationCallbacks) {
            [self returnLocationInfo:callbackId andKeepCallback:NO];
        }

        [self.locationData.locationCallbacks removeAllObjects];
    }
    if (self.locationData.watchCallbacks.count > 0) {
        for (NSString* timerId in self.locationData.watchCallbacks) {
            [self returnLocationInfo:[self.locationData.watchCallbacks objectForKey:timerId] andKeepCallback:YES];
        }
    } else {
        // No callbacks waiting on us anymore, turn off listening.
        [self _stopLocation];
    }
}

- (void)getLocation:(CDVInvokedUrlCommand*)command
{
    NSString* callbackId = command.callbackId;
    BOOL enableHighAccuracy = [[command argumentAtIndex:0] boolValue];

    if ([self isLocationServicesEnabled] == NO) {
        NSMutableDictionary* posError = [NSMutableDictionary dictionaryWithCapacity:2];
        [posError setObject:[NSNumber numberWithInt:PERMISSIONDENIED] forKey:@"code"];
        [posError setObject:@"Location services are disabled." forKey:@"message"];
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:posError];
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
    } else {
        if (!self.locationData) {
            self.locationData = [[CDVLocationData alloc] init];
        }
        CDVLocationData* lData = self.locationData;
        if (!lData.locationCallbacks) {
            lData.locationCallbacks = [NSMutableArray arrayWithCapacity:1];
        }

        if (!__locationStarted || (__highAccuracyEnabled != enableHighAccuracy)) {
            // add the callbackId into the array so we can call back when get data
            if (callbackId != nil) {
                [lData.locationCallbacks addObject:callbackId];
            }
            // Tell the location manager to start notifying us of heading updates
            [self startLocation:enableHighAccuracy];
        } else {
            [self returnLocationInfo:callbackId andKeepCallback:NO];
        }
    }
}

- (void)addWatch:(CDVInvokedUrlCommand*)command
{
    NSString* callbackId = command.callbackId;
    NSString* timerId = [command argumentAtIndex:0];
    BOOL enableHighAccuracy = [[command argumentAtIndex:1] boolValue];

    if (!self.locationData) {
        self.locationData = [[CDVLocationData alloc] init];
    }
    CDVLocationData* lData = self.locationData;

    if (!lData.watchCallbacks) {
        lData.watchCallbacks = [NSMutableDictionary dictionaryWithCapacity:1];
    }

    // add the callbackId into the dictionary so we can call back whenever get data
    [lData.watchCallbacks setObject:callbackId forKey:timerId];

    if ([self isLocationServicesEnabled] == NO) {
        NSMutableDictionary* posError = [NSMutableDictionary dictionaryWithCapacity:2];
        [posError setObject:[NSNumber numberWithInt:PERMISSIONDENIED] forKey:@"code"];
        [posError setObject:@"Location services are disabled." forKey:@"message"];
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:posError];
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
    } else {
        if (!__locationStarted || (__highAccuracyEnabled != enableHighAccuracy)) {
            // Tell the location manager to start notifying us of location updates
            [self startLocation:enableHighAccuracy];
        }
    }
}

- (void)clearWatch:(CDVInvokedUrlCommand*)command
{
    NSString* timerId = [command argumentAtIndex:0];

    if (self.locationData && self.locationData.watchCallbacks && [self.locationData.watchCallbacks objectForKey:timerId]) {
        [self.locationData.watchCallbacks removeObjectForKey:timerId];
        if([self.locationData.watchCallbacks count] == 0) {
            [self _stopLocation];
        }
    }
}

- (void)stopLocation:(CDVInvokedUrlCommand*)command
{
    [self _stopLocation];
}

- (void)returnLocationInfo:(NSString*)callbackId andKeepCallback:(BOOL)keepCallback
{
    CDVPluginResult* result = nil;
    CDVLocationData* lData = self.locationData;

    if (lData && !lData.locationInfo) {
        // return error
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:POSITIONUNAVAILABLE];
    } else if (lData && lData.locationInfo) {
        CLLocation* lInfo = lData.locationInfo;
        NSMutableDictionary* returnInfo = [NSMutableDictionary dictionaryWithCapacity:8];
        NSNumber* timestamp = [NSNumber numberWithDouble:([lInfo.timestamp timeIntervalSince1970] * 1000)];
        [returnInfo setObject:timestamp forKey:@"timestamp"];
        [returnInfo setObject:[NSNumber numberWithDouble:lInfo.speed] forKey:@"velocity"];
        [returnInfo setObject:[NSNumber numberWithDouble:lInfo.verticalAccuracy] forKey:@"altitudeAccuracy"];
        [returnInfo setObject:[NSNumber numberWithDouble:lInfo.horizontalAccuracy] forKey:@"accuracy"];
        [returnInfo setObject:[NSNumber numberWithDouble:lInfo.course] forKey:@"heading"];
        [returnInfo setObject:[NSNumber numberWithDouble:lInfo.altitude] forKey:@"altitude"];
        [returnInfo setObject:[NSNumber numberWithDouble:lInfo.coordinate.latitude] forKey:@"latitude"];
        [returnInfo setObject:[NSNumber numberWithDouble:lInfo.coordinate.longitude] forKey:@"longitude"];

        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:returnInfo];
        [result setKeepCallbackAsBool:keepCallback];
    }
    if (result) {
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
    }
}

- (void)returnLocationError:(NSUInteger)errorCode withMessage:(NSString*)message
{
    NSMutableDictionary* posError = [NSMutableDictionary dictionaryWithCapacity:2];

    [posError setObject:[NSNumber numberWithUnsignedInteger:errorCode] forKey:@"code"];
    [posError setObject:message ? message:@"" forKey:@"message"];
    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:posError];

    for (NSString* callbackId in self.locationData.locationCallbacks) {
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
    }

    [self.locationData.locationCallbacks removeAllObjects];

    for (NSString* callbackId in self.locationData.watchCallbacks) {
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
    }
}

- (void)locationManager:(CLLocationManager*)manager didFailWithError:(NSError*)error
{
    NSLog(@"locationManager::didFailWithError %@", [error localizedFailureReason]);

    CDVLocationData* lData = self.locationData;
    if (lData && __locationStarted) {
        // TODO: probably have to once over the various error codes and return one of:
        // PositionError.PERMISSION_DENIED = 1;
        // PositionError.POSITION_UNAVAILABLE = 2;
        // PositionError.TIMEOUT = 3;
        NSUInteger positionError = POSITIONUNAVAILABLE;
        if (error.code == kCLErrorDenied) {
            positionError = PERMISSIONDENIED;
        }
        [self returnLocationError:positionError withMessage:[error localizedDescription]];
    }

    if (error.code != kCLErrorLocationUnknown) {
      [self.locationManager stopUpdatingLocation];
      __locationStarted = NO;
    }
}

//iOS8+
-(void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status
{
    if(!__locationStarted){
        [self startLocation:__highAccuracyEnabled];
    }
}

- (void)dealloc
{
    self.locationManager.delegate = nil;
}

- (void)onReset
{
    [self _stopLocation];
    [self.locationManager stopUpdatingHeading];
}

#pragma mark - MB Region Monitoring: Interface
- (void)startMonitoringRegion:(CDVInvokedUrlCommand*)command
{
	NSString * callbackId = command.callbackId;
	NSString * identifier = command.arguments[0];
	float lat = [command.arguments[1] floatValue];
	float lon = [command.arguments[2] floatValue];
	float radius = [command.arguments[3] floatValue];

	// make sure we're not monitoring too many events
	if (self.locationManager.monitoredRegions.count > 19)
	{
		[self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Unable to add region. You've reached the maximum of 20. To proceed, remove regions or remove all. Then try again."] callbackId:callbackId];
		return;
	}
	
	// create the CLRegion
	CLLocationCoordinate2D center = CLLocationCoordinate2DMake(lat, lon);
	CLCircularRegion * region = [[CLCircularRegion alloc] initWithCenter:center radius:radius identifier:identifier];
	region.notifyOnEntry = YES;
	region.notifyOnExit = NO;
	
	// verify region monitoring availability and permissions
	if (![CLLocationManager isMonitoringAvailableForClass:[CLCircularRegion class]])
	{
		[self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Geofencing is not supported on this device!"] callbackId:callbackId];
		return;
	}
	if ([CLLocationManager authorizationStatus] != kCLAuthorizationStatusAuthorizedAlways)
	{
		[self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Region wass saved but will only be activated once user grants permission to access the device location."] callbackId:callbackId];
		return;
	}
	
	// all good, now try to add the region
	if (!self.locationData.regionMonitoringCallbacks)
	{
		self.locationData.regionMonitoringCallbacks = [NSMutableDictionary new];
	}
	if (!self.locationData.regionMonitoringCallbacks[identifier])
	{
		self.locationData.regionMonitoringCallbacks[identifier] = [NSMutableArray new];
	}
	
	[self.locationData.regionMonitoringCallbacks[identifier] addObject:callbackId];
	[self.locationManager startMonitoringForRegion:region];
}

- (void)stopMonitoringRegion:(CDVInvokedUrlCommand*)command
{
	NSString * callbackId = command.callbackId;
	NSString * identifier = [command.arguments[0] stringValue];
	CLCircularRegion * regionToStop;
	
	for (CLCircularRegion * region in self.locationManager.monitoredRegions)
	{
		if ([region.identifier isEqualToString:identifier])
		{
			regionToStop = region;
			[self.locationManager stopMonitoringForRegion:region];
			break;
		}
	}
	
	CDVPluginResult * result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:[self dictionaryFromRegion:(CLCircularRegion *)regionToStop]];
	[self.commandDelegate sendPluginResult:result callbackId:callbackId];
}

- (void)stopMonitoringAllRegions:(CDVInvokedUrlCommand*)command
{
	NSString * callbackId = command.callbackId;
	
	for (CLCircularRegion * region in self.locationManager.monitoredRegions)
	{
		[self.locationManager stopMonitoringForRegion:region];
	}
	
	[self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:callbackId];
}

#pragma mark - MB Region Monitoring: CLLocationManager Delegate Methods
- (void)locationManager:(CLLocationManager *)manager didStartMonitoringForRegion:(nonnull CLRegion *)region
{
	NSLog(@"Successfully monitoring region: %@", region.identifier);
	/* Not doing this because you wouldn't be able to distinguish it from didEnterRegion (which is really what the success callback wants)
	for (NSString * identifier in self.locationData.regionMonitoringCallbacks)
	{
		if ([identifier isEqualToString:region.identifier])
		{
			for (NSString * callbackId in self.locationData.regionMonitoringCallbacks[identifier])
			{
				[self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:callbackId];
			}
			break;
		}
	}
	*/
}

- (void)locationManager:(CLLocationManager *)manager monitoringDidFailForRegion:(nullable CLRegion *)region withError:(nonnull NSError *)error
{
	NSLog(@"Failed monitoring for region: %@ with error: %@", region.identifier, error);
	for (NSString * identifier in self.locationData.regionMonitoringCallbacks)
	{
		if ([identifier isEqualToString:region.identifier])
		{
			for (NSString * callbackId in self.locationData.regionMonitoringCallbacks[identifier])
			{
				CDVPluginResult * result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self dictionaryFromRegion:(CLCircularRegion *)region]];
				[self.commandDelegate sendPluginResult:result callbackId:callbackId];
			}
			break;
		}
	}
}

- (void)locationManager:(CLLocationManager *)manager didEnterRegion:(CLRegion *)region
{
	[self logRegionEntry:(CLCircularRegion *)region];
	for (NSString * identifier in self.locationData.regionMonitoringCallbacks)
	{
		if ([identifier isEqualToString:region.identifier])
		{
			for (NSString * callbackId in self.locationData.regionMonitoringCallbacks[identifier])
			{
				CDVPluginResult * result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:[self dictionaryFromRegion:(CLCircularRegion *)region]];
				[self.commandDelegate sendPluginResult:result callbackId:callbackId];
			}
			break;
		}
	}
}

- (void)logRegionEntry:(CLCircularRegion *)region
{
	NSString * postString = [NSString stringWithFormat:@"GEOFENCING: Region \"%@\" entered. (lat: %f, lon:%f)", region.identifier, region.center.latitude, region.center.longitude];
	
	NSURLSession * session = [NSURLSession sharedSession];
	NSMutableURLRequest * request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api-dev.boosterfuels.com/phone-home"]];
	request.HTTPMethod = @"POST";
	request.HTTPBody = [postString dataUsingEncoding:NSUTF8StringEncoding];
	
	[[session dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error)
	{

	}] resume];
}

- (NSDictionary *)dictionaryFromRegion:(CLCircularRegion *)region
{
	return @{
			 @"identifier": region.identifier,
			 @"latitude": [NSNumber numberWithFloat:region.center.latitude],
			 @"longitude": [NSNumber numberWithFloat:region.center.longitude],
			 @"timestamp": @([[NSDate date] timeIntervalSince1970]),
			 };
}

@end
