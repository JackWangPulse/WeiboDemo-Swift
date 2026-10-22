# Swift 闭包解耦案例：`onAction`

## 1. 使用闭包把 Cell 中的事件传递给 Controller

`FeedContentView` 只负责识别用户点击了什么，并通过闭包把事件向外传递：

```swift
var onAction: ((FeedAction) -> Void)?

func didTap(_ action: FeedAction) {
    onAction?(action)
}
```

`FeedCell` 将闭包继续转发给内部的 `FeedContentView`：

```swift
var onAction: ((FeedAction) -> Void)? {
    didSet {
        contentNode.onAction = onAction
    }
}
```

Controller 在配置 Cell 时注入真正的处理逻辑：

```swift
cell.onAction = { [weak self] action in
    self?.handle(action)
}
```

以点击 `.more` 为例，完整调用过程是：

```text
FeedContentView 识别点击
        ↓
onAction?(.expand(itemID))
        ↓
执行 Controller 注入的闭包
        ↓
FeedViewController.handle(.expand(itemID))
```

这里的 `[weak self]` 可以避免 Cell 保存闭包、闭包又强引用 Controller 而形成循环引用。

## 2. 闭包为什么能带来解耦

如果 `FeedContentView` 直接调用 Controller：

```swift
controller?.expand(itemID)
```

那么 View 必须知道具体的 `FeedViewController`，也会逐渐知道页面跳转、数据更新等业务细节。

改为闭包后，View 只需要表达用户意图：

```swift
onAction?(.expand(itemID))
```

它不需要知道事件最终由谁处理，也不知道正文具体怎样展开。Controller 则通过闭包决定收到事件以后做什么。

因此职责变成：

```text
FeedContentView：识别并输出事件
FeedCell：转发事件
FeedViewController：处理业务
```

核心作用可以概括为：

> 下层 View 不再依赖具体的上层 Controller，而是由上层通过闭包注入处理方式，从而提高复用性和可测试性。
