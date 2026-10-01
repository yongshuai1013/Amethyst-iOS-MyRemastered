//
//  AIMessageCell.m
//  Amethyst
//

#import "AIMessageCell.h"
#import "MarkdownParser.h"
#import "LauncherPreferences.h"

// 说明：助手气泡采用白 0.08 半透明底，聊天气泡不叠加 UIVisualEffectView 毛玻璃，
// 以避免滚动表格中反复插入模糊视图导致的性能/复用问题；外层内容区已由
// BackgroundManager 提供整体毛玻璃，气泡透出即可。参考 AnnouncementCardCell 的处理。

/// 内容字体
static const CGFloat kMsgFontSize = 16.0;
/// 气泡内边距
static const CGFloat kMsgBubblePadding = 10.0;
/// 气泡最大宽度占容器比例
static const CGFloat kMsgMaxBubbleWidthRatio = 0.72;
/// 水平外边距
static const CGFloat kMsgHMargin = 12.0;
/// cell 上下留白
static const CGFloat kMsgVerticalPadding = 10.0;
/// 气泡圆角（连续圆角）
static const CGFloat kMsgCornerRadius = 12.0;

@interface AIMessageCell ()
@property (nonatomic, strong) UIView *bubbleView;
@property (nonatomic, strong) UITextView *contentTextView;
@property (nonatomic, strong) UIView *toolCardView;
@property (nonatomic, strong) UILabel *toolCardLabel;
/// 思考过程折叠标签（助手消息有 reasoning 时显示在气泡顶部，点击展开/收起）
@property (nonatomic, strong) UILabel *reasoningLabel;
/// 正文顶部约束（无思考块时贴气泡顶 / 有思考块时接思考标签底部，二选一激活）
@property (nonatomic, strong) NSLayoutConstraint *contentTopPlain;
@property (nonatomic, strong) NSLayoutConstraint *contentTopWithReasoning;
/// 当前渲染的消息（供思考块点击回调）
@property (nonatomic, strong, nullable) AiMessage *currentMessage;
@end

@implementation AIMessageCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        self.bubbleView = [[UIView alloc] init];
        self.bubbleView.translatesAutoresizingMaskIntoConstraints = NO;
        self.bubbleView.layer.cornerRadius = kMsgCornerRadius;
        self.bubbleView.layer.cornerCurve = kCACornerCurveContinuous;
        self.bubbleView.clipsToBounds = YES;
        [self.contentView addSubview:self.bubbleView];

        self.contentTextView = [[UITextView alloc] init];
        self.contentTextView.translatesAutoresizingMaskIntoConstraints = NO;
        self.contentTextView.editable = NO;
        self.contentTextView.scrollEnabled = NO;
        self.contentTextView.selectable = YES;
        self.contentTextView.backgroundColor = [UIColor clearColor];
        self.contentTextView.textContainerInset = UIEdgeInsetsZero;
        self.contentTextView.textContainer.lineFragmentPadding = 0;
        [self.bubbleView addSubview:self.contentTextView];

        // 思考过程折叠标签：默认隐藏，有 reasoning 的助手消息才显示
        self.reasoningLabel = [[UILabel alloc] init];
        self.reasoningLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.reasoningLabel.font = [UIFont systemFontOfSize:12.0];
        self.reasoningLabel.textColor = [UIColor secondaryLabelColor];
        self.reasoningLabel.numberOfLines = 1;
        self.reasoningLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        self.reasoningLabel.hidden = YES;
        self.reasoningLabel.userInteractionEnabled = YES;
        [self.bubbleView addSubview:self.reasoningLabel];
        [NSLayoutConstraint activateConstraints:@[
            [self.reasoningLabel.topAnchor constraintEqualToAnchor:self.bubbleView.topAnchor constant:kMsgBubblePadding - 2],
            [self.reasoningLabel.leadingAnchor constraintEqualToAnchor:self.bubbleView.leadingAnchor constant:kMsgBubblePadding],
            [self.reasoningLabel.trailingAnchor constraintEqualToAnchor:self.bubbleView.trailingAnchor constant:-kMsgBubblePadding],
        ]];
        UITapGestureRecognizer *reasonTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(reasoningTapped)];
        [self.reasoningLabel addGestureRecognizer:reasonTap];

        // 约束：文本顶/左/右贴气泡内边距，从内容尺寸撑起气泡高度（不主动撑起）
        // 有思考块时正文改接思考标签底部（contentTopWithReasoning），二选一激活
        self.contentTopPlain = [self.contentTextView.topAnchor constraintEqualToAnchor:self.bubbleView.topAnchor constant:kMsgBubblePadding];
        self.contentTopWithReasoning = [self.contentTextView.topAnchor constraintEqualToAnchor:self.reasoningLabel.bottomAnchor constant:6.0];
        self.contentTopWithReasoning.active = NO;
        [NSLayoutConstraint activateConstraints:@[
            self.contentTopPlain,
            [self.contentTextView.leadingAnchor constraintEqualToAnchor:self.bubbleView.leadingAnchor constant:kMsgBubblePadding],
            [self.contentTextView.trailingAnchor constraintEqualToAnchor:self.bubbleView.trailingAnchor constant:-kMsgBubblePadding],
            [self.contentTextView.bottomAnchor constraintEqualToAnchor:self.bubbleView.bottomAnchor constant:-kMsgBubblePadding],
            // 限制气泡最大宽度
            [self.bubbleView.widthAnchor constraintLessThanOrEqualToAnchor:self.contentView.widthAnchor multiplier:kMsgMaxBubbleWidthRatio],
        ]];

        // 气泡垂直方向由内容顶/底撑起，再由 cell 上下留白约束 min 高度
        [NSLayoutConstraint activateConstraints:@[
            [self.bubbleView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:kMsgVerticalPadding],
            [self.bubbleView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-kMsgVerticalPadding],
        ]];

        // 工具卡片：居中紧凑系统样式（隐藏时不影响气泡布局）
        self.toolCardView = [[UIView alloc] init];
        self.toolCardView.translatesAutoresizingMaskIntoConstraints = NO;
        self.toolCardView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
        self.toolCardView.layer.cornerRadius = 8.0;
        self.toolCardView.layer.cornerCurve = kCACornerCurveContinuous;
        self.toolCardView.clipsToBounds = YES;
        self.toolCardView.hidden = YES;
        [self.contentView addSubview:self.toolCardView];

        self.toolCardLabel = [[UILabel alloc] init];
        self.toolCardLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.toolCardLabel.font = [UIFont systemFontOfSize:11.0];
        self.toolCardLabel.textColor = [UIColor tertiaryLabelColor];
        self.toolCardLabel.numberOfLines = 0;
        self.toolCardLabel.backgroundColor = [UIColor clearColor];
        [self.toolCardView addSubview:self.toolCardLabel];

        [NSLayoutConstraint activateConstraints:@[
            // 卡片水平居中，两侧保留边距
            [self.toolCardView.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [self.toolCardView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.leadingAnchor constant:kMsgHMargin],
            [self.toolCardView.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-kMsgHMargin],
            [self.toolCardView.widthAnchor constraintLessThanOrEqualToAnchor:self.contentView.widthAnchor multiplier:kMsgMaxBubbleWidthRatio],
            // 卡片垂直居中，cell 上下留白包裹（内边距 6）
            [self.toolCardView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
            [self.toolCardView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],
            [self.toolCardLabel.topAnchor constraintEqualToAnchor:self.toolCardView.topAnchor constant:5],
            [self.toolCardLabel.bottomAnchor constraintEqualToAnchor:self.toolCardView.bottomAnchor constant:-5],
            [self.toolCardLabel.leadingAnchor constraintEqualToAnchor:self.toolCardView.leadingAnchor constant:10],
            [self.toolCardLabel.trailingAnchor constraintEqualToAnchor:self.toolCardView.trailingAnchor constant:-10],
        ]];
    }
    return self;
}

- (void)configureWithMessage:(AiMessage *)message markdownEnabled:(BOOL)enabled {
    if (!message) return;

    // 工具结果：渲染为居中系统卡片（仅显示成功/失败状态）
    if (message.isToolResult) {
        self.bubbleView.hidden = YES;
        self.toolCardView.hidden = NO;
        self.toolCardLabel.text = [[self class] toolCardTextForMessage:message];
        return;
    }

    self.toolCardView.hidden = YES;
    self.bubbleView.hidden = NO;
    BOOL isUser = [message.role isEqualToString:@"user"];
    self.currentMessage = message;
    // 思考过程折叠块：仅助手消息且有 reasoning 时显示（工具结果卡片已提前返回，不影响）
    BOOL showReasoning = !isUser && message.reasoning.length > 0;
    if (showReasoning) {
        self.reasoningLabel.hidden = NO;
        self.reasoningLabel.numberOfLines = message.reasoningExpanded ? 0 : 1;
        if (message.reasoningExpanded) {
            self.reasoningLabel.text = message.reasoning;
        } else {
            self.reasoningLabel.text = [NSString stringWithFormat:@"💭 思考过程（%lu字）· 点击展开",
                                        (unsigned long)message.reasoning.length];
        }
        self.contentTopPlain.active = NO;
        self.contentTopWithReasoning.active = YES;
    } else {
        self.reasoningLabel.hidden = YES;
        self.contentTopWithReasoning.active = NO;
        self.contentTopPlain.active = YES;
    }
    // 工具调用消息与 AI 的话共存：气泡显示 AI 文本并附加工具调用提示
    NSString *content = message.isToolCall ? [[self class] displayContentForMessage:message] : (message.content ?: @"");
    UIColor *contentColor = [UIColor labelColor];

    // 文本内容
    if (isUser || !enabled) {
        UIFont *font = [UIFont systemFontOfSize:kMsgFontSize];
        self.contentTextView.font = font;
        self.contentTextView.text = content;
        self.contentTextView.textColor = contentColor;
    } else {
        NSAttributedString *attr = [MarkdownParser parseMarkdown:content baseFont:[UIFont systemFontOfSize:kMsgFontSize]];
        self.contentTextView.attributedText = attr;
    }

    // 气泡样式
    if (isUser) {
        // 用户消息：右对齐，accent 色调 0.10 底 + labelColor 文字
        self.bubbleView.backgroundColor = [accentColor() colorWithAlphaComponent:0.10];
        self.contentTextView.textColor = contentColor;
        [self rebuildHorizontalConstraintsForUser:YES];
    } else {
        // 助手消息：左对齐，白 0.08 底 + MarkdownParser 内置系统文字色 + 毛玻璃
        self.bubbleView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        [self rebuildHorizontalConstraintsForUser:NO];
    }
}

/// 重建气泡水平对齐约束（用户右对齐，助手左对齐）
- (void)rebuildHorizontalConstraintsForUser:(BOOL)isUser {
    // 移除此前添加的水平对齐约束（识别存储的标记）
    NSMutableArray *toRemove = [NSMutableArray array];
    for (NSLayoutConstraint *c in [self.contentView constraints]) {
        BOOL touchesBubble = (c.firstItem == self.bubbleView || c.secondItem == self.bubbleView);
        BOOL horizontal = (c.firstAttribute == NSLayoutAttributeLeading ||
                           c.firstAttribute == NSLayoutAttributeTrailing ||
                           c.secondAttribute == NSLayoutAttributeLeading ||
                           c.secondAttribute == NSLayoutAttributeTrailing);
        if (touchesBubble && horizontal) {
            [toRemove addObject:c];
        }
    }
    if (toRemove.count > 0) {
        [NSLayoutConstraint deactivateConstraints:toRemove];
    }

    if (isUser) {
        // 右对齐
        [NSLayoutConstraint activateConstraints:@[
            [self.bubbleView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-kMsgHMargin],
            [self.bubbleView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.leadingAnchor constant:kMsgHMargin],
        ]];
    } else {
        // 左对齐
        [NSLayoutConstraint activateConstraints:@[
            [self.bubbleView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:kMsgHMargin],
            [self.bubbleView.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-kMsgHMargin],
        ]];
    }
}

/// 思考块点击：交由 VC 翻转展开态并刷新该行
- (void)reasoningTapped {
    if (self.onReasoningToggle && self.currentMessage) {
        self.onReasoningToggle(self.currentMessage);
    }
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.currentMessage = nil;
    self.onReasoningToggle = nil;
    self.reasoningLabel.hidden = YES;
    self.contentTopWithReasoning.active = NO;
    self.contentTopPlain.active = YES;
}

#pragma mark - 工具卡片文本

/// 工具调用消息用于气泡显示的内容：AI 的话 + 工具调用状态行（共存）
+ (NSString *)displayContentForMessage:(AiMessage *)message {
    if (message.isToolCall) {
        NSString *base = message.content ?: @"";
        // 关键修复（工具名显示 call_00_...）：toolName 缺失时显示通用"工具"，
        // 绝不用 toolCallID（形如 call_xxx 的一串 id）顶替真实工具名
        NSString *name = message.toolName.length > 0 ? message.toolName : @"工具";
        NSString *state = message.toolRunning ? @"正在调用" : @"已调用";
        NSMutableString *s = [NSMutableString string];
        if (base.length > 0) {
            [s appendString:base];
            [s appendString:@"\n\n"];
        }
        [s appendFormat:@"⚙️ %@：%@", state, name];
        // 参数预览（截断拼单行，避免长 JSON 撑爆气泡）
        if (message.toolArguments.length > 0) {
            NSString *args = [[message.toolArguments componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]
                              componentsJoinedByString:@" "];
            if (args.length > 80) args = [[args substringToIndex:80] stringByAppendingString:@"…"];
            [s appendFormat:@"（%@）", args];
        } else if (base.length == 0) {
            [s appendString:@"…"];
        }
        return [s copy];
    }
    return message.content ?: @"";
}

+ (NSString *)toolCardTextForMessage:(AiMessage *)message {
    if (!message) return @"";
    // 关键修复（工具名显示 call_00_...）：toolName 缺失时显示通用"工具"，
    // 不用 toolCallID（call_xxx）顶替真实工具名
    NSString *name = message.toolName.length > 0 ? message.toolName : @"工具";
    if (message.isToolResult) {
        // 只显示执行成功/失败状态，不展示冗长的工具返回正文（避免占满屏幕）
        return message.toolSucceeded ? [NSString stringWithFormat:@"✅ %@ 执行成功", name] : [NSString stringWithFormat:@"❌ %@ 执行失败", name];
    }
    return [NSString stringWithFormat:@"⚙️ 工具：%@", name];
}

#pragma mark - 高度估算

+ (CGFloat)cellHeightForMessage:(AiMessage *)message width:(CGFloat)width markdownEnabled:(BOOL)enabled {
    if (!message || !width) return 60.0;

    // 工具结果：渲染为小卡片，仅按状态文本行高估算
    if (message.isToolResult) {
        NSString *cardText = [self toolCardTextForMessage:message];
        CGFloat maxCardWidth = width * kMsgMaxBubbleWidthRatio - 20; // 扣左右内边距
        if (maxCardWidth < 20) maxCardWidth = 20;
        UIFont *font = [UIFont systemFontOfSize:11.0];
        CGRect r = [cardText boundingRectWithSize:CGSizeMake(maxCardWidth, CGFLOAT_MAX)
                                          options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                       attributes:@{NSFontAttributeName: font}
                                          context:nil];
        CGFloat textHeight = ceil(r.size.height);
        if (textHeight < 16) textHeight = 16;
        // 文字上下内边距 5*2 + 卡片上下留白 6*2
        CGFloat total = textHeight + 5 * 2 + 6 * 2;
        return MAX(total, 40.0);
    }

    // 工具调用消息与 AI 的话共存在气泡中，按普通气泡文本计算高度
    NSString *content = message.isToolCall ? [self displayContentForMessage:message] : (message.content ?: @"");
    CGFloat maxBubbleWidth = width * kMsgMaxBubbleWidthRatio;
    CGFloat textWidth = maxBubbleWidth - 2 * kMsgBubblePadding;
    if (textWidth < 20) textWidth = 20;

    BOOL isUser = [message.role isEqualToString:@"user"];
    CGSize textSize;
    if (isUser || !enabled) {
        UIFont *font = [UIFont systemFontOfSize:kMsgFontSize];
        CGRect r = [content boundingRectWithSize:CGSizeMake(textWidth, CGFLOAT_MAX)
                                         options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                      attributes:@{NSFontAttributeName: font}
                                         context:nil];
        textSize = r.size;
    } else {
        NSAttributedString *attr = [MarkdownParser parseMarkdown:content baseFont:[UIFont systemFontOfSize:kMsgFontSize]];
        CGRect r = [attr boundingRectWithSize:CGSizeMake(textWidth, CGFLOAT_MAX)
                                      options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                      context:nil];
        textSize = r.size;
    }

    CGFloat textHeight = ceil(textSize.height);
    if (textHeight < 20) textHeight = 20;
    CGFloat total = textHeight + 2 * kMsgBubblePadding + 2 * kMsgVerticalPadding;
    // 思考折叠块高度（与 configure 渲染一致：12pt，收起 1 行 + 6 间距，展开按全文估算）
    if (!isUser && !message.isToolResult && message.reasoning.length > 0) {
        CGFloat reasoningHeight;
        if (message.reasoningExpanded) {
            UIFont *rFont = [UIFont systemFontOfSize:12.0];
            CGRect rr = [message.reasoning boundingRectWithSize:CGSizeMake(textWidth, CGFLOAT_MAX)
                                                       options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                    attributes:@{NSFontAttributeName: rFont}
                                                       context:nil];
            reasoningHeight = ceil(rr.size.height);
        } else {
            reasoningHeight = ceil([UIFont systemFontOfSize:12.0].lineHeight);
        }
        total += reasoningHeight + 6.0;
    }
    return MAX(total, 48.0);
}

@end