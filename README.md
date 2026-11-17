# airvent
An intermediate single-file lua events library, with variable conditional triggering.


# Functions

## airvent.new()
```lua
av = airvent.new({[env], [autoWatch], [maxRecursion], [onError], [historyLimit]})
```
Creates and returns a new airvent event instance. Store it to a variable, then set triggers.

### Parameters
1. `env` (table): Environment table to watch instead of `_ENV` or `_G`.
2. `autoWatch` (bool): Enables automatic variable hooking. Default `true`.
3. `maxRecursion` (num): Maximum nested depth for a trigger before error. Default `15`.
4. `onError` (function): Custom error function `(err)`. Default prints `"[airvent Error]"`.
5. `historyLimit` (num): Maximum number of fired trigger records stored in history. Default `50`.

---

## instance.trigger()
```lua
unsub = av.trigger(name, [condition], callback, [{[priority], [once], [edgeTriggered], [vars], [debounce], [throttle]}])
```
Registers a listener callback to a named trigger, optionally tied to a reactive condition. Returns a function to unsubscribe the listener.

### Parameters
1. `name` (string): Non-empty trigger name. Cannot be a reserved method name (`"trigger"`, `"check"`, `"destroy"`, `"pause"`, `"resume"`, `"remove"`, `"reset"`, `"watch"`, `"set"`, `"update"`, `"waitFor"`, `"inspect"`, `"history"`).
2. `condition` (string | function): Optional Lua expression string or predicate function returning a boolean. Supports `#`, `..`, and whitelisted math/string/type helpers.
3. `callback` (function): Function `(event)` run when triggered. Receives `event.name`, `event.data`, `event.cancelled`, and `event:cancel()`.
4. `opts` (table): Optional configuration table:
   * `priority` (num): Execution order where higher numbers run first. Default `0`.
   * `once` (bool): Removes listener after firing once. Default `false`.
   * `edgeTriggered` (bool): Fires only when condition changes from `false` to `true`. Default `true`.
   * `vars` (table): Array of variable names to watch when `condition` is a function.
   * `debounce` (num): Delays firing until `dt` seconds pass without re-triggering. Requires `av.update(dt)`.
   * `throttle` (num): Limits firing to at most once every `dt` seconds. Requires `av.update(dt)`.

---

## instance.triggerName()
```lua
data, cancelled = av.<triggerName>([payload])
```
Evaluates all conditional triggers, then dynamically fires the named trigger. Returns the payload data and whether the event was cancelled.

### Parameters
1. `payload` (any): Optional data passed to `event.data` in the listener callbacks. Default `{}`.

---

## instance.check()
```lua
av.check()
```
Manually evaluates all registered conditional triggers against the current scope (locals, upvalues, and globals).

### Parameters
* None.

---

## instance.pause()
```lua
av.pause(name)
```
Temporarily disables a trigger so it will not evaluate conditions or fire listeners.

### Parameters
1. `name` (string): Name of the trigger to pause.

---

## instance.resume()
```lua
av.resume(name)
```
Re-enables a previously paused trigger.

### Parameters
1. `name` (string): Name of the trigger to resume.

---

## instance.remove()
```lua
removed = av.remove(name)
```
Deletes a trigger and all of its registered listeners from the instance. Returns `true` if the trigger existed and was removed, or `false` otherwise.

### Parameters
1. `name` (string): Name of the trigger to remove.

---

## instance.reset()
```lua
av.reset(name)
```
Resets an edge-triggered condition's state back to `false` and clears any pending debounce timer so it can fire again immediately.

### Parameters
1. `name` (string): Name of the trigger to reset.

---

## instance.watch()
```lua
proxy = av.watch(tbl, [rootName])
```
Recursively wraps a table and its nested sub-tables in metatable proxies so deep property mutations automatically evaluate conditional triggers. Returns the wrapped table.

### Parameters
1. `tbl` (table): Table to watch for nested changes.
2. `rootName` (string): Optional top-level variable name to register in the watched environment.

---

## instance.set()
```lua
av.set(path, value)
```
Sets a value on a top-level or nested variable path and immediately evaluates all conditional triggers.

### Parameters
1. `path` (string): Dot-separated variable path (e.g. `"player.stats.hp"`).
2. `value` (any): Value to assign at the target path.

---

## instance.update()
```lua
av.update(dt)
```
Advances internal timers for debounced triggers, throttled triggers, and `waitFor()` coroutine timeouts. Call this inside your main loop.

### Parameters
1. `dt` (num): Non-negative delta time in seconds elapsed since the last update.

---

## instance.waitFor()
```lua
ok, result = av.waitFor(conditionOrName, [timeout])
```
Yields the running coroutine until a named event fires or a condition becomes `true`. Returns `true` with the event payload on match, or `false` with `"timeout"` or `"destroyed"` if interrupted.

### Parameters
1. `conditionOrName` (string | function): Trigger name, Lua expression string, or predicate function returning a boolean.
2. `timeout` (num): Optional maximum wait time in seconds before resuming with `false, "timeout"`.

---

## instance.inspect()
```lua
info = av.inspect(name)
```
Returns a snapshot table containing a trigger's current configuration and runtime state, or `nil` if the trigger does not exist.

### Parameters
1. `name` (string): Name of the trigger to inspect.

---

## instance.history()
```lua
entries = av.history([limit])
```
Returns an array of recently fired trigger records containing `name`, `timestamp`, `elapsed`, and `data`.

### Parameters
1. `limit` (num): Optional maximum number of most recent entries to return. Defaults to all stored entries up to `historyLimit`.

---

## instance.destroy()
```lua
av.destroy()
```
Restores the original environment table, unwraps proxied tables, resumes pending coroutine waiters, and clears all active triggers.

### Parameters
* None.
