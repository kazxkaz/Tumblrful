/**
 * @file TumblrPost.m
 * @brief TumblrPost implementation
 * @author Masayuki YAMAYA
 * @date 2008-03-07
 */
#import "TumblrPost.h"
#import "Log.h"
#import <WebKit/WebKit.h>
#import <Foundation/NSXMLDocument.h>

//#define V(format, ...)	Log(format, __VA_ARGS__)
#define V(format, ...)

static NSString* WRITE_URL = @"http://www.tumblr.com/api/write";
static NSString* TUMBLR_URL = @"http://www.tumblr.com";
static NSString* EXCEPTION_NAME = @"TumblrPostException";
static float TIMEOUT = 60.0;

#pragma mark -
@interface NSString (URLEncoding)
- (NSString*) stringByURLEncoding:(NSStringEncoding)encoding;
@end

@implementation NSString (URLEncoding)
/**
 * URL エンコーディングを行う
 * @param [in] encoding エンコーディング
 * @return NSString オブジェクト
 */
- (NSString*) stringByURLEncoding:(NSStringEncoding)encoding
{
	NSArray* escapeChars = [NSArray arrayWithObjects:
			 @";" ,@"/" ,@"?" ,@":"
			,@"@" ,@"&" ,@"=" ,@"+"
			,@"$" ,@"," ,@"[" ,@"]"
			,@"#" ,@"!" ,@"'" ,@"("
			,@")" ,@"*"
			,nil];

	NSArray* replaceChars = [NSArray arrayWithObjects:
			  @"%3B" ,@"%2F" ,@"%3F"
			 ,@"%3A" ,@"%40" ,@"%26"
			 ,@"%3D" ,@"%2B" ,@"%24"
			 ,@"%2C" ,@"%5B" ,@"%5D"
			 ,@"%23" ,@"%21" ,@"%27"
			 ,@"%28" ,@"%29" ,@"%2A"
			 ,nil];

	NSMutableString* encodedString =
		[[[self stringByAddingPercentEscapesUsingEncoding:encoding] mutableCopy] autorelease];

	const int N = [escapeChars count];
	int i;
	for (i = 0; i < N; i++) {
		[encodedString replaceOccurrencesOfString:[escapeChars objectAtIndex:i]
									   withString:[replaceChars objectAtIndex:i]
										  options:NSLiteralSearch
											range:NSMakeRange(0, [encodedString length])];
	}

	return [NSString stringWithString: encodedString];
}
@end

#pragma mark -
@interface TumblrReblogDelegate : NSObject
{
	NSString* endpoint_;	/**< url */
	TumblrPost*	continuation_;
	NSMutableData* responseData_;	/**< for NSURLConnection */
}
- (id) initWithEndpoint:(NSString*)endpoint continuation:(TumblrPost*)continuation;
- (void) dealloc;
@end
#define FIX_20080702
#pragma mark -
@interface TumblrPost (Private)
- (void) invokeCallback:(SEL)selector withObject:(NSObject*)param;
- (NSString*) detectPostType:(NSArray*)inputs;
- (NSMutableDictionary*) collectInputFieldsAsLink:(NSArray*)elements;
- (NSMutableDictionary*) collectInputFieldsAsPhoto:(NSArray*)elements;
- (NSMutableDictionary*) collectInputFieldsAsQuote:(NSArray*)elements;
- (NSMutableDictionary*) collectInputFieldsAsRegular:(NSArray*)elements;
- (NSMutableDictionary*) collectInputFieldsAsChat:(NSArray*)elements;
- (NSMutableDictionary*) collectInputFieldsAsVideo:(NSArray*)elements;
#ifdef FIX_20080702 
- (void) addElementIfFormKey:(NSXMLElement*)element fields:(NSMutableDictionary*)fields;
#endif
// TODO: support "audio"
- (NSArray*) collectInputFields:(NSData*)form;
- (void) reblogPost:(NSString*)endpoint form:(NSData*)formData;
@end

@implementation TumblrPost (Private)
/**
 * MainThread上でコールバックする
 */
- (void) invokeCallback:(SEL)selector withObject:(NSObject*)param
{
	if (callback_) {
		V(@"TumblrPost.callback_ respondsToSelector: %d", [callback_ respondsToSelector:selector]);
		if ([callback_ respondsToSelector:selector]) {
			[callback_ performSelectorOnMainThread:selector withObject:param waitUntilDone:NO];
		}
	}
}

/**
 * form HTMLからfieldを得る.
 * @param formData フォームデータ
 * @return フィールド(DOM要素)
 */
- (NSArray*) collectInputFields:(NSData*)formData
{
	static NSString* EXPR = @"//div[@id=\"container\"]/div[@id=\"content\"]/form[@id=\"edit_post\"]//(input[starts-with(@name, \"post\")] | textarea[starts-with(@name, \"post\")] | input[@id=\"form_key\"])";

	/* UTF-8 文字列にしないと後の [attribute stringValue] で日本語がコードポイント表記になってしまう */
	NSString* html = [[[NSString alloc] initWithData:formData encoding:NSUTF8StringEncoding] autorelease];
	//V(@"form: %@", html);

	/* DOMにする */
	NSError* error = nil;
	NSXMLDocument* document = [[NSXMLDocument alloc] initWithXMLString:html options:NSXMLDocumentTidyHTML error:&error];
	if (document == nil) {
		[NSException raise:EXCEPTION_NAME format:@"Couldn't make DOMDocument. error: %@", [error description]];
	}

	NSArray* inputs = [[document rootElement] nodesForXPath:EXPR error:&error];
	if (inputs == nil) {
		[NSException raise:EXCEPTION_NAME format:@"Failed nodesForXPath. error: %@", [error description]];
	}

	return inputs;
}

/**
 * input(NSXMLElement) array から post[type] の value を得る
 */
- (NSString*) detectPostType:(NSArray*)inputs
{
	NSRange empty = NSMakeRange(NSNotFound, 0);

	NSEnumerator* enumerator = [inputs objectEnumerator];
	NSXMLElement* element;
	while ((element = [enumerator nextObject]) != nil) {

		NSString* name = [[element attributeForName:@"name"] stringValue];

		if (!NSEqualRanges([name rangeOfString:@"post[type]"], empty)) {
			return [[element attributeForName:@"value"] stringValue];
		}
	}
	return nil;
}

/**
 * "Link" post type の時の input fields の抽出
 */
- (NSMutableDictionary*) collectInputFieldsAsLink:(NSArray*)elements
{
	NSMutableDictionary* fields = [[NSMutableDictionary alloc] init];
	[fields setValue:@"link" forKey:@"post[type]"];

	NSEnumerator* enumerator = [elements objectEnumerator];
	NSRange empty = NSMakeRange(NSNotFound, 0);
	NSXMLElement* element;
	while ((element = [enumerator nextObject]) != nil) {

		NSString* name = [[element attributeForName:@"name"] stringValue];
		NSXMLNode* attribute;
		NSString* value;

		if (!NSEqualRanges([name rangeOfString:@"post[one]"], empty)) {
			attribute = [element attributeForName:@"value"];
			value = [attribute stringValue];
			[fields setValue:value forKey:@"post[one]"];
		}
		else if (!NSEqualRanges([name rangeOfString:@"post[two]"], empty)) {
			[fields setValue:[[element attributeForName:@"value"] stringValue] forKey:@"post[two]"];
		}
		else if (!NSEqualRanges([name rangeOfString:@"post[three]"], empty)) {
			[fields setValue:[element stringValue] forKey:@"post[three]"];
		}
#ifdef FIX_20080702
		else {
			[self addElementIfFormKey:element fields:fields];
		}
#endif
	}

	V(@"fields(Link): %@", [fields description]);
	return fields;
}

/**
 * "Photo" post type の時の input fields の抽出
 */
- (NSMutableDictionary*) collectInputFieldsAsPhoto:(NSArray*)elements
{
	NSMutableDictionary* fields = [[NSMutableDictionary alloc] init];
	[fields setValue:@"photo" forKey:@"post[type]"];

	NSEnumerator* enumerator = [elements objectEnumerator];
	NSRange empty = NSMakeRange(NSNotFound, 0);
	NSXMLElement* element;
	while ((element = [enumerator nextObject]) != nil) {

		NSString* name = [[element attributeForName:@"name"] stringValue];
		NSXMLNode* attribute;

		if (!NSEqualRanges([name rangeOfString:@"post[one]"], empty)) {
			/* one は出現しない？ */
			Log(@"post[one] is not implemented in Reblog(Photo).");
		}
		else if (!NSEqualRanges([name rangeOfString:@"post[two]"], empty)) {
			[fields setValue:[element stringValue] forKey:@"post[two]"];
		}
		else if (!NSEqualRanges([name rangeOfString:@"post[three]"], empty)) {
			attribute = [element attributeForName:@"value"];
			[fields setValue:[attribute stringValue] forKey:@"post[three]"];
		}
#ifdef FIX_20080702
		else {
			[self addElementIfFormKey:element fields:fields];
		}
#endif
	}

	V(@"fields(Photo): %@", [fields description]);
	return fields;
}

/**
 * "Quote" post type の時の input fields の抽出
 */
- (NSMutableDictionary*) collectInputFieldsAsQuote:(NSArray*)elements
{
	NSMutableDictionary* fields = [[NSMutableDictionary alloc] init];
	[fields setValue:@"quote" forKey:@"post[type]"];

	NSEnumerator* enumerator = [elements objectEnumerator];
	NSRange empty = NSMakeRange(NSNotFound, 0);
	NSXMLElement* element;
	while ((element = [enumerator nextObject]) != nil) {

		NSString* name = [[element attributeForName:@"name"] stringValue];

		if (!NSEqualRanges([name rangeOfString:@"post[one]"], empty)) {
			[fields setValue:[element stringValue] forKey:@"post[one]"];
		}
		else if (!NSEqualRanges([name rangeOfString:@"post[two]"], empty)) {
			[fields setValue:[element stringValue] forKey:@"post[two]"];
		}
		else if (!NSEqualRanges([name rangeOfString:@"post[three]"], empty)) {
			/* three は出現しない？ */
			Log(@"post[three] is not implemented in Reblog(Quote).");
		}
#ifdef FIX_20080702
		else {
			[self addElementIfFormKey:element fields:fields];
		}
#endif
	}

	V(@"fields(Quote): %@", [fields description]);
	return fields;
}

/**
 * "Regular" post type の時の input fields の抽出
 */
- (NSMutableDictionary*) collectInputFieldsAsRegular:(NSArray*)elements
{
	NSMutableDictionary* fields = [[NSMutableDictionary alloc] init];
	[fields setValue:@"regular" forKey:@"post[type]"];

	NSEnumerator* enumerator = [elements objectEnumerator];
	NSRange empty = NSMakeRange(NSNotFound, 0);
	NSXMLElement* element;
	while ((element = [enumerator nextObject]) != nil) {

		NSString* name = [[element attributeForName:@"name"] stringValue];
		NSXMLNode* attribute;

		if (!NSEqualRanges([name rangeOfString:@"post[one]"], empty)) {
			attribute = [element attributeForName:@"value"];
			[fields setValue:[attribute stringValue] forKey:@"post[one]"];
		}
		else if (!NSEqualRanges([name rangeOfString:@"post[two]"], empty)) {
			[fields setValue:[element stringValue] forKey:@"post[two]"];
		}
		else if (!NSEqualRanges([name rangeOfString:@"post[three]"], empty)) {
			/* three は出現しない？ */
			Log(@"post[three] is not implemented in Reblog(Quote).");
		}
#ifdef FIX_20080702
		else {
			[self addElementIfFormKey:element fields:fields];
		}
#endif
	}

	V(@"fields(Regular): %@", [fields description]);
	return fields;
}

/**
 * "Conversation" post type の時の input fields の抽出
 */
- (NSMutableDictionary*) collectInputFieldsAsChat:(NSArray*)elements
{
	NSMutableDictionary* fields = [[NSMutableDictionary alloc] init];
	[fields setValue:@"conversation" forKey:@"post[type]"];

	NSEnumerator* enumerator = [elements objectEnumerator];
	NSRange empty = NSMakeRange(NSNotFound, 0);
	NSXMLElement* element;
	while ((element = [enumerator nextObject]) != nil) {

		NSString* name = [[element attributeForName:@"name"] stringValue];

		if (!NSEqualRanges([name rangeOfString:@"post[one]"], empty)) {
			NSXMLNode* attribute = [element attributeForName:@"value"];
			[fields setValue:[attribute stringValue] forKey:@"post[one]"];
		}
		else if (!NSEqualRanges([name rangeOfString:@"post[two]"], empty)) {
			[fields setValue:[element stringValue] forKey:@"post[two]"];
		}
		else if (!NSEqualRanges([name rangeOfString:@"post[three]"], empty)) {
			/* three は出現しない？ */
			Log(@"post[three] is not implemented in Reblog(Conversation).");
		}
#ifdef FIX_20080702
		else {
			[self addElementIfFormKey:element fields:fields];
		}
#endif
	}

	V(@"fields(Chat): %@", [fields description]);
	return fields;
}

/**
 * "Video" post type の時の input fields の抽出
 */
- (NSMutableDictionary*) collectInputFieldsAsVideo:(NSArray*)elements
{
	NSMutableDictionary* fields = [[NSMutableDictionary alloc] init];
	[fields setValue:@"video" forKey:@"post[type]"];

	NSEnumerator* enumerator = [elements objectEnumerator];
	NSRange empty = NSMakeRange(NSNotFound, 0);
	NSXMLElement* element;
	while ((element = [enumerator nextObject]) != nil) {

		NSString* name = [[element attributeForName:@"name"] stringValue];

		if (!NSEqualRanges([name rangeOfString:@"post[one]"], empty)) {
			[fields setValue:[element stringValue] forKey:@"post[one]"];
		}
		else if (!NSEqualRanges([name rangeOfString:@"post[two]"], empty)) {
			[fields setValue:[element stringValue] forKey:@"post[two]"];
		}
		else if (!NSEqualRanges([name rangeOfString:@"post[three]"], empty)) {
			/* three は出現しない？ */
			Log(@"post[three] is not implemented in Reblog(Video).");
		}
#ifdef FIX_20080702
		else {
			[self addElementIfFormKey:element fields:fields];
		}
#endif
	}

	V(@"fields(Video): %@", [fields description]);
	return fields;
}

#ifdef FIX_20080702 
/**
 * elementの要素名がformKeyであれば fields に追加する.
 */
- (void) addElementIfFormKey:(NSXMLElement*)element fields:(NSMutableDictionary*)fields
{
	NSRange empty = NSMakeRange(NSNotFound, 0);
	NSString* name = [[element attributeForName:@"name"] stringValue];

	if (!NSEqualRanges([name rangeOfString:@"form_key"], empty)) {
		NSXMLNode* attribute = [element attributeForName:@"value"];
		V(@"form_key=%@", [attribute stringValue]);
		[fields setValue:[attribute stringValue] forKey:@"form_key"];
	}
}
#endif /* FIX_20080702 */

/**
 * reblogPost.
 * @param endpoint ポスト先のURI
 * @param formData form データ
 */
- (void) reblogPost:(NSString*)endpoint form:(NSData*)formData
{
	NSArray* inputs = [self collectInputFields:formData];
	NSString* type = [self detectPostType:inputs];

	V(@"reblogPost: inputs: %@", [inputs description]);
	V(@"reblogPost: type: %@", type);

	if (type != nil) {
		NSMutableDictionary* fields = nil;

		if ([type isEqualToString:@"link"]) {
			fields = [self collectInputFieldsAsLink:inputs];
		}
		else if ([type isEqualToString:@"photo"]) {
			fields = [self collectInputFieldsAsPhoto:inputs];
		}
		else if ([type isEqualToString:@"quote"]) {
			fields = [self collectInputFieldsAsQuote:inputs];
		}
		else if ([type isEqualToString:@"regular"]) {
			fields = [self collectInputFieldsAsRegular:inputs];
		}
		else if ([type isEqualToString:@"conversation"]) {
			fields = [self collectInputFieldsAsChat:inputs];
		}
		else if ([type isEqualToString:@"video"]) {
			fields = [self collectInputFieldsAsVideo:inputs];
		}
		else {
			[NSException raise:EXCEPTION_NAME format:@"Unknwon Reblog form. post type was invalid. type: %@", SafetyDescription(type)];
			return;
		}
		if (fields == nil) {
			[NSException raise:EXCEPTION_NAME format:@"Unknwon Reblog form. not found post[one|two|three] fields. type: %@", SafetyDescription(type)];
			return;
		}
		else if ([fields count] < 2) { /* type[post] + 1このフィールドは絶対あるはず */
			[NSException raise:EXCEPTION_NAME format:@"Unknwon Reblog form. too few fields. type: %@", SafetyDescription(type)];
			return;
		}

		NSMutableDictionary* params = [[[NSMutableDictionary alloc] init] autorelease];
		[params setValue:type forKey:@"type"];
		if (queuing_)
			[params setValue:@"2" forKey:@"post[state]"];	// queuing post
		[params addEntriesFromDictionary:fields];

		/* Tumblrへポストする */
		[self postTo:endpoint params:params];
	}
}
@end

#pragma mark -
@implementation TumblrReblogDelegate
/**
 */
- (id) initWithEndpoint:(NSString*)endpoint
					 continuation:(TumblrPost*)continuation
{
	if ((self = [super init]) != nil) {
		endpoint_ = [endpoint retain];
		continuation_ = [continuation retain];
		responseData_ = nil;
	}
	return self;
}

/**
 */
- (void) dealloc
{
	if (endpoint_ != nil) {
		[endpoint_ release];
		endpoint_ = nil;
	}
	if (continuation_ != nil) {
		[continuation_ release];
		continuation_ = nil;
	}
	if (responseData_ != nil) {
		[responseData_ release];
		responseData_ = nil;
	}
	[super dealloc];
}

/**
 * didReceiveResponse デリゲートメソッド.
 *	@param connection NSURLConnection オブジェクト
 *	@param response NSURLResponse オブジェクト
 */
- (void) connection:(NSURLConnection*)connection
 didReceiveResponse:(NSURLResponse*)response
{
	/* この cast は正しい */
	NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;

	V(@"didReceiveResponse: statusCode=%d", [httpResponse statusCode]);

	if ([httpResponse statusCode] == 200) {
		responseData_ = [[NSMutableData data] retain];
	}
}

/**
 * didReceiveData デリゲートメソッド.
 *	@param connection NSURLConnection オブジェクト
 *	@param response data NSData オブジェクト
 */
- (void) connection:(NSURLConnection*)connection
		 didReceiveData:(NSData*)data
{
	if (responseData_ != nil) {
		V(@"didReceiveData: append length=%d", [data length]);
		[responseData_ appendData:data];
	}
}

/**
 * connectionDidFinishLoading.
 * @param connection コネクション
 */
- (void) connectionDidFinishLoading:(NSURLConnection*)connection
{
	V(@"didReceiveData: connectionDidFinishLoading length=%d", [responseData_ length]);

	if (continuation_ != nil) {
		[continuation_ reblogPost:endpoint_ form:responseData_];
	}
	else {
		NSError* error = [NSError errorWithDomain:@"TumblrfulErrorDomain" code:-1 userInfo:nil];
		[continuation_ invokeCallback:@selector(failed:) withObject:error]; /* 失敗時の処理 */
	}
	if (responseData_ != nil) {
		[responseData_ release];
	}
	[self release];
}

/**
 * エラーが発生した場合.
 * @param connection コネクション
 */
- (void) connection:(NSURLConnection*)connection didFailWithError:(NSError*)error
{
	V(@"didFailWithError: %@", [error description]);
	[self release];
}
@end // TumblrReblogDelegate

#pragma mark -
@implementation TumblrPost
/**
 * PostCallback 付きの生成
 */
- (id) initWithCallback:(NSObject<PostCallback>*)callback
{
	if ((self = [super init]) != nil) {
		callback_ = [callback retain];

		NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
		private_ = [defaults boolForKey:@"TumblrfulPrivate"];
		queuing_ = [defaults boolForKey:@"TumblrfulQueuing"];
		responseData_ = nil;
	}
	return self;
}

/**
 * オブジェクトの解放.
 */
- (void) dealloc
{
	if (callback_ != nil) {
		[callback_ release];
		callback_ = nil;
	}
	if (responseData_ != nil) {
		[responseData_ release];
		responseData_ = nil;
	}
	[super dealloc];
}

/**
 * set to private.
 * @param private trueの場合プライベートポストにする
 */
- (void) setPrivate:(BOOL)private
{
	private_ = private;
}

/**
 * get private.
 * @return trueの場合プライベートポストを示す
 */
- (BOOL) private
{
	return private_;
}

/**
 * get mail address of account on tumblr.
 */
+ (NSString*) username
{
	CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("TumblrfulEmail"), kCFPreferencesCurrentApplication);
	if (value != nil) {
		return [NSString stringWithFormat:@"%@", value];
	}
	return nil;
}

/**
 * get passowrd of account on tumblr
 */
+ (NSString*) password
{
	CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("TumblrfulPassword"), kCFPreferencesCurrentApplication);
	if (value != nil) {
		return [NSString stringWithFormat:@"%@", value];
	}
	return nil;
}

/**
 * create minimum request param for Tumblr
 */
- (NSMutableDictionary*) createMinimumRequestParams
{
	NSMutableArray* keys = [NSMutableArray arrayWithObjects:@"email", @"password", @"generator", nil];
	NSMutableArray* objs = [NSMutableArray arrayWithObjects: [TumblrPost username], [TumblrPost password], @"Tumblrful", nil];
	if ([self private]) {
		[keys addObject:@"private"];
		[objs addObject:@"1"];
	}
	return [[NSMutableDictionary alloc] initWithObjects:objs forKeys:keys];
}

/**
 * create POST request
 */
- (NSURLRequest*) createRequest:(NSString*)url params:(NSDictionary*)params
{
	NSMutableString* escaped = [[[NSMutableString alloc] init] autorelease];

	/* create the body */
	/* add key-values from the NSDictionary object */
	NSEnumerator* enumerator = [params keyEnumerator];
	NSString* key;
	while ((key = [enumerator nextObject]) != nil) {
        NSObject* any = [params objectForKey:key]; 
		NSString* value;
        if ([any isMemberOfClass:[NSURL class]]) {
            value = [(NSURL*)any absoluteString];
        }
        else {
            value = (NSString*)any;
        }
		value = [value stringByURLEncoding:NSUTF8StringEncoding];
		[escaped appendFormat:@"&%@=%@", key, value];
	}

	/* create the POST request */
	NSMutableURLRequest* request =
		[NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
								cachePolicy:NSURLRequestReloadIgnoringCacheData
							timeoutInterval:TIMEOUT];
	[request setHTTPMethod:@"POST"];
	[request setHTTPBody:[escaped dataUsingEncoding:NSUTF8StringEncoding]];
	V(@"body: %@", escaped);

	return request;
}

#ifdef SUPPORT_MULTIPART_PORT
/**
 * create multipart POST request
 */
-(NSURLRequest*) createRequestForMultipart:(NSDictionary*)params withData:(NSData*)data
{
	static NSString* HEADER_BOUNDARY = @"0xKhTmLbOuNdArY";

	// create the URL POST Request to tumblr
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:WRITE_URL]];

	[request setHTTPMethod:@"POST"];

	// add the header to request
	[request addValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", HEADER_BOUNDARY] forHTTPHeaderField: @"Content-Type"];

	// create the body
	NSMutableData* body = [NSMutableData data];
	[body appendData:[[NSString stringWithFormat:@"--%@\r\n", HEADER_BOUNDARY] dataUsingEncoding:NSUTF8StringEncoding]];

	// add key-values from the NSDictionary object
	NSEnumerator* enumerator = [params keyEnumerator];
	NSString* key;
	while ((key = [enumerator nextObject]) != nil) {
		[body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n\r\n", key] dataUsingEncoding:NSUTF8StringEncoding]];
		[body appendData:[[NSString stringWithFormat:@"%@", [params objectForKey:key]] dataUsingEncoding:NSUTF8StringEncoding]];
		[body appendData:[[NSString stringWithFormat:@"\r\n--%@\r\n", HEADER_BOUNDARY] dataUsingEncoding:NSUTF8StringEncoding]];
	}

	// add data field and file data
	[body appendData:[[NSString stringWithString:@"Content-Disposition: form-data; name=\"data\"\r\n"] dataUsingEncoding:NSUTF8StringEncoding]];
	[body appendData:[[NSString stringWithString:@"Content-Type: application/octet-stream\r\n\r\n"] dataUsingEncoding:NSUTF8StringEncoding]];
	[body appendData:[NSData dataWithData:data]];
	[body appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", HEADER_BOUNDARY] dataUsingEncoding:NSUTF8StringEncoding]];

	// add the body to the post
	[request setHTTPBody:body];

	return request;
}
#endif /* SUPPORT_MULTIPART_PORT */

/**
 * post to Tumblr.
 *	@param params - request parameteres
 */
- (void) postWith:(NSDictionary*)params
{
	[self postTo:WRITE_URL params:params];
}

/**
 * post to Tumblr.
 *	@param url - URL to post
 *	@param params - request parameteres
 */
- (void) postTo:(NSString*)url params:(NSDictionary*)params
{
	responseData_ = [[NSMutableData data] retain];

	NSURLRequest* request = [self createRequest:url params:params]; /* request は connection に指定した時点で reatin upする */ 
	//V(@"TumblrPost.postTo: %@", [request description]);

	NSURLConnection* connection = [NSURLConnection connectionWithRequest:request delegate:self];
	[connection retain];

	if (connection == nil) {
		[self invokeCallback:@selector(failed:) withObject:nil];
		[responseData_ release];
		responseData_ = nil;
		return;
	}
}

/**
 * reblog
 *	@param postID ポストのID(整数値)
 */
#ifdef FIX20080412
- (NSObject*) reblog:(NSString*)postID key:(NSString*)reblogKey
#else
- (NSObject*) reblog:(NSString*)postID
#endif
{
#ifdef FIX20080412
	NSString* endpoint = [NSString stringWithFormat:@"%@/reblog/%@/%@", TUMBLR_URL, postID, reblogKey];
#else
	NSString* endpoint = [NSString stringWithFormat:@"%@/reblog/%@", TUMBLR_URL, postID];
#endif
	V(@"Reblog form URL: %@", endpoint);

	NSURLRequest* request =
		[NSURLRequest requestWithURL:[NSURL URLWithString:endpoint]];

	TumblrReblogDelegate* delegate =
		[[TumblrReblogDelegate alloc] initWithEndpoint:endpoint continuation:self];
	[delegate retain];

	NSURLConnection* connection =
		[NSURLConnection connectionWithRequest:request delegate:delegate];

	V(@"connection: %p", connection);
	if (connection == nil) {
		[NSException raise:EXCEPTION_NAME format:@"Couldn't get Reblog form. endpoint: %@", endpoint];
	}

	return @""; /* なんとかならんかなぁ */
}

/**
 * didReceiveResponse デリゲートメソッド
 *	@param connection NSURLConnection オブジェクト
 *	@param response NSURLResponse オブジェクト
 *
 *	正常なら statusCode は 201
 *	Account 不正なら 403
 */
- (void) connection:(NSURLConnection*)connection didReceiveResponse:(NSURLResponse*)response
{
	NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response; /* この cast は正しい */

	NSInteger httpStatus = [httpResponse statusCode];
	if (httpStatus != 201 && httpStatus != 200) {
		Log(@"TumblrPost.didReceiveResponse statusCode: %d", [httpResponse statusCode]);
		Log(@"TumblrPost.didReceiveResponse ResponseHeader: %@", [[httpResponse allHeaderFields] description]);
	}

	[responseData_ setLength:0]; // initialize receive buffer
}

/**
 * didReceiveData
 *	delegate method
 */
- (void) connection:(NSURLConnection*)connection didReceiveData:(NSData*)data
{
	//V(@"TumblrPost.didReceiveData data=%@", [data description]);
	[responseData_ appendData:data]; // append data to receive buffer
}

/**
 * connectionDidFinishLoading
 *	delegate method
 */
- (void) connectionDidFinishLoading:(NSURLConnection*)connection
{
	V(@"TumblrPost.DidFinishLoading succeeded to load %d bytes", [responseData_ length]);

	[connection release];

	if (callback_ != nil) {
		[self invokeCallback:@selector(posted:) withObject:responseData_];
	}
	else {
		NSError* error = [NSError errorWithDomain:@"TumblrfulErrorDomain" code:-1 userInfo:nil];
		[self invokeCallback:@selector(failed:) withObject:error];
	}

	[responseData_ release]; /* release receive buffer */
	[self release];
}

/**
 * didFailWithError
 *	delegate method
 */
- (void) connection:(NSURLConnection*)connection didFailWithError:(NSError*)error
{
	V(@"TumblrPost.didFailWithError: NSError:@%", [error description]);

	[connection release];

	[responseData_ release];	/* release receive buffer */

	[self invokeCallback:@selector(failed:) withObject:error];
	[self release];
}
@end