# Example

A working chat app: an agent with tools, streaming answers, a stop button,
lifecycle-bound cancellation, human approval for a destructive tool, and a live
trace panel.

```sh
cd example
flutter run          # any platform — it needs no key and no network
```

It runs against a scripted model, so it works offline and behaves identically
every time. Replace `FakeChatModel` with `OpenAiCompatibleChatModel` (or any
other adapter) and nothing else in the app changes.
