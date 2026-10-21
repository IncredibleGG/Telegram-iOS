//
//  RMIntroPageView.m
//  IntroOpenGL
//
//  Created by Ilya Rimchikov on 05.12.13.
//  Copyright (c) 2013 Ilya Rimchikov. All rights reserved.
//

#import "RMIntroPageView.h"

@implementation RMIntroPageView
{
    // LuminaGram: the footnote part of _description (NSNotFound when there is none) and the
    // label width its font was last fitted to. See initWithFrame and luminaFitFootnote.
    NSRange _footnoteRange;
    CGFloat _footnoteFittedWidth;
}

#define IPAD ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad)

- (id)initWithFrame:(CGRect)frame headline:(NSString*)headline description:(NSString*)description color:(UIColor *)color
{
    self = [super initWithFrame:frame];
    if (self) {
        // Initialization code
        
        
        //self.backgroundColor=[UIColor redColor];
        self.opaque=YES;
        _headline=headline;
        
        UILabel *headlineLabel = [[UILabel alloc]initWithFrame:CGRectMake(0, 0, frame.size.width, 64+8)];
        headlineLabel.font = [UIFont boldSystemFontOfSize:35.0]; //[UIFont fontWithName:@"HelveticaNeue-Light" size:IPAD ? 96/2 : 36];
        headlineLabel.text = _headline;
        headlineLabel.textColor = color;
        headlineLabel.textAlignment = NSTextAlignmentCenter;
        headlineLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleWidth;
        _headerLabel = headlineLabel;
      
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        style.lineSpacing = IPAD ? 4 : 3;
        style.lineBreakMode = NSLineBreakByWordWrapping;
        style.alignment = NSTextAlignmentCenter;
        

        // LuminaGram: text after a blank line ("\n\n") is a footnote, drawn as one smaller, dimmer
        // line under the main text. Tour.Text1 uses it for "Powered by the Telegram API, part of
        // the Telegram ecosystem." The page only has room for about three lines of 17pt text
        // between the headline and the page dots, so the footnote stays on a single line (its
        // font shrinks to the label width, see luminaFitFootnote) and the label moves down a
        // little to keep the main text clear of the headline. Pages without "\n\n" are unchanged.
        NSString *mainText = description;
        NSString *footnoteText = nil;
        NSRange footnoteSeparator = [description rangeOfString:@"\n\n"];
        if (footnoteSeparator.location != NSNotFound) {
            mainText = [description substringToIndex:footnoteSeparator.location];
            footnoteText = [description substringFromIndex:footnoteSeparator.location + footnoteSeparator.length];
        }
        _footnoteRange = NSMakeRange(NSNotFound, 0);
        _footnoteFittedWidth = 0.0;

        NSMutableArray *boldRanges = [[NSMutableArray alloc] init];
        
        NSMutableString *cleanText = [[NSMutableString alloc] initWithString:mainText];
        while (true)
        {
            NSRange startRange = [cleanText rangeOfString:@"**"];
            if (startRange.location == NSNotFound)
                break;
            
            [cleanText deleteCharactersInRange:startRange];
            
            NSRange endRange = [cleanText rangeOfString:@"**"];
            if (endRange.location == NSNotFound)
                break;
            
            [cleanText deleteCharactersInRange:endRange];
            
            [boldRanges addObject:[NSValue valueWithRange:NSMakeRange(startRange.location, endRange.location - startRange.location)]];
        }
        
        _description = [[NSMutableAttributedString alloc]initWithString:cleanText];
        NSDictionary *boldAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
                                        [UIFont boldSystemFontOfSize:IPAD ? 22 : 17.0], NSFontAttributeName, nil];
        for (NSValue *nRange in boldRanges)
        {
            [_description addAttributes:boldAttributes range:[nRange rangeValue]];
        }
        
        if (footnoteText.length != 0) {
            [_description appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:footnoteText]]];
            _footnoteRange = NSMakeRange(cleanText.length + 1, footnoteText.length);
        }

        [_description addAttribute:NSParagraphStyleAttributeName
                             value:style
                             range:NSMakeRange(0, _description.length)];
        [_description addAttribute:NSForegroundColorAttributeName value:color range:NSMakeRange(0, _description.length)];
        
        CGFloat footnoteOffset = 0.0;
        if (_footnoteRange.location != NSNotFound) {
            NSMutableParagraphStyle *footnoteStyle = [style mutableCopy];
            footnoteStyle.paragraphSpacingBefore = IPAD ? 6 : 4;
            [_description addAttribute:NSParagraphStyleAttributeName value:footnoteStyle range:_footnoteRange];
            [_description addAttribute:NSForegroundColorAttributeName value:[color colorWithAlphaComponent:0.6] range:_footnoteRange];
            [_description addAttribute:NSFontAttributeName value:[UIFont systemFontOfSize:IPAD ? 16.0 : 13.0] range:_footnoteRange];
            footnoteOffset = 6.0;
        }

        UILabel *descriptionLabel = [[UILabel alloc]initWithFrame:CGRectMake(0, 25 + (IPAD ? 22 : 0) + footnoteOffset, frame.size.width, 120+8+5)];
        descriptionLabel.font = [UIFont systemFontOfSize:IPAD ? 22 : 17.0];
        descriptionLabel.attributedText = _description;
        descriptionLabel.numberOfLines=0;
        descriptionLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleWidth;
        [self addSubview:descriptionLabel];
        _descriptionLabel = descriptionLabel;
        [self luminaFitFootnote];
        
        [self addSubview:headlineLabel];
        
        
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    [self luminaFitFootnote];
}

// LuminaGram: keep the footnote on one line - the largest font from the default size down to
// 10pt that fits the label width (it only shrinks on narrow screens). Re-run when the width
// changes.
- (void)luminaFitFootnote
{
    if (_footnoteRange.location == NSNotFound || _descriptionLabel == nil) {
        return;
    }
    CGFloat width = _descriptionLabel.bounds.size.width;
    if (width <= 0.0 || fabs(width - _footnoteFittedWidth) < 0.5) {
        return;
    }
    _footnoteFittedWidth = width;

    NSString *footnote = [_description.string substringWithRange:_footnoteRange];
    CGFloat fontSize = IPAD ? 16.0 : 13.0;
    while (fontSize > 10.0 && [footnote sizeWithAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:fontSize]}].width > width - 16.0) {
        fontSize -= 0.5;
    }
    [_description addAttribute:NSFontAttributeName value:[UIFont systemFontOfSize:fontSize] range:_footnoteRange];
    _descriptionLabel.attributedText = _description;
}


/*
// Only override drawRect: if you perform custom drawing.
// An empty implementation adversely affects performance during animation.
- (void)drawRect:(CGRect)rect
{
    // Drawing code
}
*/

@end
