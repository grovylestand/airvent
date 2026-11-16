# airvent
An intermediate single-file lua events library, with variable conditional triggering.


# Functions

## airvent.new()
```lua
av = airvent.new({[env], [autoWatch], [maxRecursion], [onError]})
```
Creates and returns a new airvent event instance. Store it to a variable, then set triggers.

### Parameters
1. `env` (table): Environment table to watch instead of `_ENV` or `_G`.
2. `autoWatch` (bool): Enables automatic variable hooking. Default `true`.
3. `maxRecursion` (num): Maximum nested depth for a trigger before error. Default `15`.
4. `onError` (function): Custom error function `(err)`. Default prints `"[airvent Error]"`.

---

## instance.trigger()
```lua
unsub = av.trigger(name, [condition], callback, [{[priority], [once], [edgeTriggered], [vars]}])
```
Registers a listener callback to a named trigger, optionally tied to a reactive condition. Returns a function to unsubscribe the listener.

### Parameters
1. `name` (string): Non-empty trigger name. Cannot be `"trigger"`, `"check"`, or `"destroy"`.
2. `condition` (string | function): Optional Lua expression string or predicate function returning a boolean.
3. `callback` (function): Function `(event)` run when triggered. Receives `event.name`, `event.data`, `event.cancelled`, and `event:cancel()`.
4. `opts` (table): Optional configuration table:
   * `priority` (num): Execution order where higher numbers run first. Default `0`.
   * `once` (bool): Removes listener after firing once. Default `false`.
   * `edgeTriggered` (bool): Fires only when condition changes from `false` to `true`. Default `true`.
   * `vars` (table): Array of variable names to watch when `condition` is a function.

---

## av.triggerName()
```lua
data, cancelled = av.<triggerName>([payload])
```
Evaluates all conditional triggers, then dynamically fires the named trigger. Returns the payload data and whether the event was cancelled.

### Parameters
1. `payload` (any): Optional data passed to `event.data` in the listener callbacks. Default `{}`.

---

## av.check()
```lua
av.check()
```
Manually evaluates all registered conditional triggers against the current scope (locals, upvalues, and globals).

### Parameters
* None.

---

## av.destroy()
```lua
av.destroy()
```
Restores the original environment table, removes metatable hooks, and clears all active triggers.

### Parameters
* None.
