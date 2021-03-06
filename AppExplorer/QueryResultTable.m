// Copyright (c) 2008 Simon Fell
//
// Permission is hereby granted, free of charge, to any person obtaining a 
// copy of this software and associated documentation files (the "Software"), 
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense, 
// and/or sell copies of the Software, and to permit persons to whom the 
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included 
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS 
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE 
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN 
// THE SOFTWARE.
//

#import "QueryResultTable.h"
#import "zkSObject.h"
#import "ZKQueryResult.h"
#import "EditableQueryResultWrapper.h"

@interface QueryResultTable ()
- (NSArray *)createTableColumns:(ZKQueryResult *)qr;
- (NSArray *)buildColumnListFromQueryResult:(ZKQueryResult *)qr;
@end

@interface QueryColumn : NSObject {
	NSString		*name;
	NSMutableArray	*childCols;
}
@end

@implementation QueryColumn
-(id)initWithName:(NSString *)n {
	self = [super init];
	name = [n copy];
	childCols = nil;
	return self;
}

-(void)dealloc {
	[name release];
	[childCols release];
	[super dealloc];
}

+(QueryColumn *)columnWithName:(NSString *)name {
	return [[[QueryColumn alloc] initWithName:name] autorelease];
}

-(NSString *)name {
	return name;
}

-(BOOL)isEqual:(id)anObject {
	return [name isEqualToString:[anObject name]];
}

-(void)addChildCol:(QueryColumn *)c {
	if (childCols == nil) {
		childCols = [[NSMutableArray array] retain];
		[childCols addObject:c];
		return;
	}
	if (![childCols containsObject:c])
		[childCols addObject:c];
}

-(void)addChildCols:(NSArray *)cols {
	for (QueryColumn *c in cols)
		[self addChildCol:c];
}

-(NSArray *)allNames {
	if (childCols == nil) return [NSArray arrayWithObject:name];
	NSMutableArray *c = [NSMutableArray arrayWithCapacity:[childCols count]];
	for (QueryColumn *qc in childCols)
		[c addObjectsFromArray:[qc allNames]];
	return c;
}

-(BOOL)hasChildNames {
	return childCols != nil;
}

@end

@implementation QueryResultTable

@synthesize table, delegate;

- (id)initForTableView:(NSTableView *)view {
	self = [super init];
	table = view;
	return self;
}

- (void)dealloc {
	[queryResult release];
	[wrapper removeObserver:self forKeyPath:@"hasCheckedRows"];
	[wrapper release];
	[super dealloc];
}

- (ZKQueryResult *)queryResult {
	return queryResult;
}

- (EditableQueryResultWrapper *)wrapper {
	return wrapper;
}

-(BOOL)hasCheckedRows {
	return [wrapper hasCheckedRows];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
	if (object == wrapper) {
		[self willChangeValueForKey:@"hasCheckedRows"];
		[self didChangeValueForKey:@"hasCheckedRows"];
	}
}

- (void)updateTable {
	[wrapper setDelegate:delegate];
	[table setDelegate:wrapper];
	[table setDataSource:wrapper];
	[self showHideErrorColumn];
	[table reloadData];
}

-(void)showHideErrorColumn {
	NSTableColumn *ec = [table tableColumnWithIdentifier:ERROR_COLUMN_IDENTIFIER];
	BOOL hasErrors = [wrapper hasErrors];
	[ec setHidden:!hasErrors];
}

- (void)setQueryResult:(ZKQueryResult *)qr {
	if (qr == queryResult) return;
	[wrapper removeObserver:self forKeyPath:@"hasCheckedRows"];
	[self willChangeValueForKey:@"hasCheckedRows"];
	[wrapper autorelease];
	[queryResult autorelease];
	queryResult = [qr retain];
	wrapper = [[EditableQueryResultWrapper alloc] initWithQueryResult:qr];
	[self didChangeValueForKey:@"hasCheckedRows"];
	[wrapper addObserver:self forKeyPath:@"hasCheckedRows" options:0 context:nil];
	int idxToDelete=0;
	while ([table numberOfColumns] > 2) {
		NSString *colId = [[[table tableColumns] objectAtIndex:idxToDelete] identifier]; 
		if ([colId isEqualToString:DELETE_COLUMN_IDENTIFIER] || [colId isEqualToString:ERROR_COLUMN_IDENTIFIER]) {
			idxToDelete++;
			continue;
		}
		[table removeTableColumn:[[table tableColumns] objectAtIndex:idxToDelete]];
	}
	NSArray *cols = [self createTableColumns:qr];
	[wrapper setEditable:[cols containsObject:@"Id"]];
	[self updateTable];
}

-(void)replaceQueryResult:(ZKQueryResult *)qr {
	[queryResult autorelease];
	queryResult = [qr retain];
	[wrapper setQueryResult:queryResult];
	[self showHideErrorColumn];
	[table reloadData];
}

- (void)removeRowAtIndex:(int)row {
	if (row >= [[wrapper records] count]) return;
	id ctx = [wrapper createMutatingRowsContext];
	[wrapper remmoveRowAtIndex:row context:ctx];
	[wrapper updateRowsFromContext:ctx];
	[self updateTable];
}

- (NSArray *)createTableColumns:(ZKQueryResult *)qr {
	NSArray *cols = [self buildColumnListFromQueryResult:qr];
	for (NSString *colName in cols) {
		NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:colName];
		[[col headerCell] setStringValue:colName];
		[col setEditable:YES];
		[col setResizingMask:NSTableColumnUserResizingMask | NSTableColumnAutoresizingMask];
		if ([colName hasSuffix:@"Id"])
			[col setWidth:165];
		[table addTableColumn:col];
        [col release];
	}
	return cols;
}

- (BOOL)addColumnsFromSObject:(ZKSObject *)row withPrefix:(NSString *)prefix toList:(NSMutableArray *)columns {
	BOOL seenNull = NO;
	
	for (NSString *fn in [row orderedFieldNames]) {
		NSObject *val = [row fieldValue:fn];
		if (val == nil || val == [NSNull null]) {
			seenNull = YES;
		}
		NSString *fullName = [prefix length] > 0 ? [NSString stringWithFormat:@"%@.%@", prefix, fn] : fn;
		QueryColumn *qc = [QueryColumn columnWithName:fullName];
		if ([val isKindOfClass:[ZKSObject class]]) {
			int containerIdx = [columns indexOfObject:qc];
			if (containerIdx != NSNotFound)
				qc = [columns objectAtIndex:containerIdx];
			if (![qc hasChildNames]) {
				NSMutableArray *relatedColumns = [NSMutableArray array];
				seenNull |= [self addColumnsFromSObject:(ZKSObject *)val withPrefix:fullName toList:relatedColumns];
				[qc addChildCols:relatedColumns];
			}
			if (containerIdx == NSNotFound)
				[columns addObject:qc];

		} else {
			if (![columns containsObject:qc]) {
				[columns addObject:qc];
			}
		}
		
	}
	return seenNull;
}

- (NSArray *)buildColumnListFromQueryResult:(ZKQueryResult *)qr {
	NSMutableArray *columns = [NSMutableArray array];
	for (ZKSObject *row in [qr records]) {
		// if we didn't see any null columns, then there's no need to look at any further rows.
		if (![self addColumnsFromSObject:row withPrefix:nil toList:columns])
			break;
	}
	// now flatten the queryColumns into a set of real columns
	NSMutableArray *colNames = [NSMutableArray arrayWithCapacity:[columns count]];
	for (QueryColumn *qc in columns)
		[colNames addObjectsFromArray:[qc allNames]];
		
	return colNames;
}

@end
