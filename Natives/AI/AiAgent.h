//
//  AiAgent.h
//  Amethyst
//
//  AI 会话编排（Phase 1 简化版）：负责拼装 system + 历史 + 新用户消息，
//  调用 AiAPIClient 发起流式请求，将增量写入 session 并持久化。
//

#import <Foundation/Foundation.h>
#import "AiProvider.h"
#import "AiSession.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiAgent : NSObject

+ (instancetype)sharedAgent;

/// 当前是否有进行中的请求（供 UI 判断是否可显示"继续生成"等）
@property (nonatomic, readonly) BOOL running;

/// 发送一条用户消息，驱动流式回复
/// @param text 用户输入
/// @param session 目标会话（会就地追加用户消息与助手占位消息）
/// @param provider 当前使用的 AI 提供商
/// @param streaming 是否流式（Phase 1 恒为 YES，保留参数位）
/// @param chunkHandler 收到增量回调（主线程；delta 为最近刷新区间的内容增量）
/// @param completionHandler 结束回调（error 为空表示成功）
- (void)sendUserMessage:(NSString *)text
                session:(AiSession *)session
               provider:(AiProvider *)provider
               streaming:(BOOL)streaming
           chunkHandler:(void (^)(NSString *partial))chunkHandler
     completionHandler:(void (^)(NSError *error))completionHandler;

/// 取消当前进行的请求（供停止按钮）
- (void)stopCurrent;

/// 从上一条未完成回复处继续生成（截断续写/中断恢复；不追加用户消息，直接以现有历史开新一轮）
/// @param session 目标会话（就地追加新的助手占位消息）
- (void)continueGenerationInSession:(AiSession *)session
                           provider:(AiProvider *)provider
                       chunkHandler:(void (^)(NSString *partial))chunkHandler
                 completionHandler:(void (^)(NSError *error))completionHandler;

/// token 粗估（ASCII≈0.25/字，其余≈1/字，单条+4开销；仅用于配额显示与压缩触发，非精确计费）
+ (NSUInteger)estimatedTokensForText:(nullable NSString *)text;
+ (NSUInteger)estimatedTokensForMessages:(NSArray<AiMessage *> *)messages;

@end

NS_ASSUME_NONNULL_END