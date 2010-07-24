# cython: embedsignature=True

cimport lua
from lua cimport lua_State

cimport cpython
cimport cpython.ref
cimport cpython.bytes
cimport cpython.tuple
from cpython.ref cimport PyObject
from cpython cimport pythread

cdef extern from *:
    ctypedef char* const_char_ptr "const char*"

cdef object exc_info
from sys import exc_info

__all__ = ['LuaRuntime', 'LuaError']

DEF POBJECT = "POBJECT" # as used by LunaticPython

cdef class _LuaObject
cdef class _Lock

cdef struct py_object:
    PyObject* obj
    PyObject* runtime
    int as_index

cdef lua.luaL_Reg py_object_lib[6]
cdef lua.luaL_Reg py_lib[6]


class LuaError(Exception):
    pass

cdef class LuaRuntime:
    """The main entry point to the Lua runtime.

    Available options:

    * ``encoding``: the string encoding, defaulting to UTF-8.  If set
      to ``None``, all string values will be returned as byte strings.
      Otherwise, they will be decoded to unicode strings on the way
      from Lua to Python and unicode strings will be encoded on the
      way to Lua.  Note that ``str()`` calls on Lua objects will
      always return a unicode object.

    * ``source_encoding``: the encoding used for Lua code, defaulting to
      the string encoding or UTF-8 if the string encoding is ``None``.

    Example usage::

      >>> from lupa import LuaRuntime
      >>> lua = LuaRuntime()

      >>> lua.eval('1+1')
      2

      >>> lua_func = lua.eval('function(f, n) return f(n) end')

      >>> def py_add1(n): return n+1
      >>> lua_func(py_add1, 2)
      3
    """
    cdef lua_State *_state
    cdef _Lock _lock
    cdef tuple _raised_exception
    cdef bytes _encoding
    cdef bytes _source_encoding

    def __cinit__(self, encoding='UTF-8', source_encoding=None):
        self._state = NULL
        cdef lua_State* L = lua.lua_open()
        if L is NULL:
            raise LuaError("Failed to initialise Lua runtime")
        self._state = L
        self._lock = _Lock()
        self._encoding = None if encoding is None else encoding.encode('ASCII')
        self._source_encoding = self._encoding or b'UTF-8'

        lua.luaL_openlibs(L)
        self.init_python_lib()
        lua.lua_settop(L, 0)

    def __dealloc__(self):
        if self._state is not NULL:
            lua.lua_close(self._state)
            self._state = NULL

    cdef int reraise_on_exception(self) except -1:
        if self._raised_exception is not None:
            exception = self._raised_exception
            self._raised_exception = None
            raise exception[0], exception[1], exception[2]
        return 0

    cdef int store_raised_exception(self) except -1:
        self._raised_exception = exc_info()
        return 0

    def eval(self, lua_code):
        """Evaluate a Lua expression passed in a string.
        """
        assert self._state is not NULL
        if isinstance(lua_code, unicode):
            lua_code = (<unicode>lua_code).encode(self._source_encoding)
        return run_lua(self, b'return ' + lua_code)

    def execute(self, lua_code):
        """Execute a Lua program passed in a string.
        """
        assert self._state is not NULL
        if isinstance(lua_code, unicode):
            lua_code = (<unicode>lua_code).encode(self._source_encoding)
        return run_lua(self, lua_code)

    def require(self, modulename):
        """Load a Lua library into the runtime.
        """
        assert self._state is not NULL
        cdef lua_State *L = self._state
        if not isinstance(modulename, (bytes, unicode)):
            raise TypeError("modulename must be a string")
        lock_runtime(self)
        try:
            lua.lua_pushlstring(L, 'require', 7)
            lua.lua_rawget(L, lua.LUA_GLOBALSINDEX)
            if lua.lua_isnil(L, -1):
                lua.lua_pop(L, 1)
                raise LuaError("require is not defined")
            return call_lua(self, L, (modulename,))
        finally:
            unlock_runtime(self)

    def globals(self):
        """Return the globals defined in this Lua runtime as a Lua
        table.
        """
        assert self._state is not NULL
        cdef lua_State *L = self._state
        lock_runtime(self)
        try:
            lua.lua_pushlstring(L, '_G', 2)
            lua.lua_rawget(L, lua.LUA_GLOBALSINDEX)
            if lua.lua_isnil(L, -1):
                lua.lua_pop(L, 1)
                raise LuaError("globals not defined")
            try:
                return py_from_lua(self, L, -1)
            finally:
                lua.lua_settop(L, 0)
        finally:
            unlock_runtime(self)

    def table(self, *items, **kwargs):
        """Creates a new table with the provided items.  Positional
        arguments are placed in the table in order, keyword arguments
        are set as key-value pairs.
        """
        assert self._state is not NULL
        cdef lua_State *L = self._state
        cdef int i
        lock_runtime(self)
        try:
            lua.lua_createtable(L, len(items), len(kwargs))
            # FIXME: how to check for failure?
            for i, arg in enumerate(items):
                py_to_lua(self, L, arg, 1)
                lua.lua_rawseti(L, -2, i+1)
            for key, value in kwargs.iteritems():
                py_to_lua(self, L, key, 1)
                py_to_lua(self, L, value, 1)
                lua.lua_rawset(L, -3)
            return py_from_lua(self, L, -1)
        finally:
            lua.lua_settop(L, 0)
            unlock_runtime(self)

    cdef int register_py_object(self, bytes cname, bytes pyname, object obj) except -1:
        cdef lua_State *L = self._state
        lua.lua_pushlstring(L, cname, len(cname))
        if not py_to_lua_custom(self, L, obj, 0):
            lua.lua_pop(L, 1)
            message = b"failed to convert %s object" % pyname
            lua.luaL_error(L, message)
            raise LuaError(message.decode('ASCII', 'replace'))
        lua.lua_pushlstring(L, pyname, len(pyname))
        lua.lua_pushvalue(L, -2)
        lua.lua_rawset(L, -5)
        lua.lua_rawset(L, lua.LUA_REGISTRYINDEX)
        return 0

    cdef int init_python_lib(self) except -1:
        cdef lua_State *L = self._state

        # create 'python' lib and register our own object metatable
        lua.luaL_openlib(L, "python", py_lib, 0)
        lua.luaL_newmetatable(L, POBJECT)
        lua.luaL_openlib(L, NULL, py_object_lib, 0)
        lua.lua_pop(L, 1)

        # register global names in the module
        self.register_py_object(b'Py_None', b'none', None)
        self.register_py_object(b'eval',    b'eval', eval)

        return 0 # nothing left to return on the stack


################################################################################
# fast, re-entrant runtime locking

cdef class _Lock:
    """Fast, re-entrant locking for the LuaRuntime.

    Under uncongested conditions, the lock is never acquired but only
    counted.  Only when a second thread comes in and notices that the
    lock is needed, it acquires the lock and notifies the first thread
    to release it when it's done.  This is all made possible by the
    wonderful GIL.
    """
    cdef pythread.PyThread_type_lock _thread_lock
    cdef long _owner
    cdef int _count
    cdef int _pending_requests
    cdef bint _is_locked

    def __cinit__(self):
        self._owner = -1
        self._count = 0
        self._is_locked = False
        self._pending_requests = 0
        self._thread_lock = pythread.PyThread_allocate_lock()
        if self._thread_lock is NULL:
            raise LuaError("Failed to initialise thread lock")

    def __dealloc__(self):
        if self._thread_lock is not NULL:
            pythread.PyThread_free_lock(self._thread_lock)
            self._thread_lock = NULL

cdef inline int lock_runtime(LuaRuntime runtime) except -1:
    if not _lock_lock(runtime._lock, pythread.PyThread_get_thread_ident()):
        raise LuaError("Failed to acquire thread lock")
    return 0

cdef inline int _lock_lock(_Lock lock, long current_thread) nogil:
    # Note that this function *must* hold the GIL when being called.
    # We just use 'nogil' in the signature to make sure that no Python
    # code slips in that might free the GIL
    if lock._count:
        # locked! - by myself?
        if current_thread == lock._owner:
            lock._count += 1
            return 1
    elif not lock._pending_requests:
        # not locked, not requested - go!
        lock._owner = current_thread
        lock._count = 1
        return 1
    # need to get the real lock
    return acquire_runtime_lock(lock, current_thread)

cdef int acquire_runtime_lock(_Lock lock, long current_thread) nogil:
    # Note that this function *must* hold the GIL when being called.
    # We just use 'nogil' in the signature to make sure that no Python
    # code slips in that might free the GIL.
    if not lock._is_locked and not lock._pending_requests:
        if not pythread.PyThread_acquire_lock(lock._thread_lock, pythread.WAIT_LOCK):
            return 0
        #assert not runtime._is_locked
        lock._is_locked = True
    lock._pending_requests += 1
    with nogil:
        # wait for lock holding thread to release it
        locked = pythread.PyThread_acquire_lock(lock._thread_lock, pythread.WAIT_LOCK)
    lock._pending_requests -= 1
    #assert not lock._is_locked
    #assert lock._lock_count == 0, 'CURRENT: %x, LOCKER: %x, COUNT: %d, LOCKED: %d' % (
    #    current_thread, lock._owner, lock._count, lock._is_locked)
    if not locked:
        return 0
    lock._is_locked = True
    lock._owner = current_thread
    lock._count = 1
    return 1

cdef inline void unlock_runtime(LuaRuntime runtime) nogil:
    # Note that this function *must* hold the GIL when being called.
    # We just use 'nogil' in the signature to make sure that no Python
    # code slips in that might free the GIL

    #assert runtime._lock_owner == pythread.PyThread_get_thread_ident(), 'UNLOCK:   CURRENT: %x, LOCKER: %x, COUNT: %d, LOCKED: %d' % (
    #    pythread.PyThread_get_thread_ident(), runtime._lock_owner, runtime._lock_count, runtime._is_locked)
    #assert runtime._lock_count > 0
    runtime._lock._count -= 1
    if runtime._lock._count == 0:
        runtime._lock._owner = -1
        if runtime._lock._is_locked:
            pythread.PyThread_release_lock(runtime._lock._thread_lock)
            runtime._lock._is_locked = False


################################################################################
# Lua object wrappers

cdef class _LuaObject:
    """A wrapper around a Lua object such as a table of function.
    """
    cdef LuaRuntime _runtime
    cdef lua_State* _state
    cdef int _ref

    def __init__(self):
        raise TypeError("Type cannot be instantiated manually")

    def __dealloc__(self):
        if self._runtime is None:
            return
        cdef lua_State* L = self._state
        try:
            lock_runtime(self._runtime)
            locked = True
        except:
            locked = False
        lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, self._ref)
        if locked:
            unlock_runtime(self._runtime)
        # undo additional INCREF at instantiation time
        cpython.ref.Py_DECREF(self._runtime)

    cdef inline int push_lua_object(self) except -1:
        cdef lua_State* L = self._state
        lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, self._ref)
        if lua.lua_isnil(L, -1):
            lua.lua_pop(L, 1)
            raise LuaError("lost reference")

    def __call__(self, *args):
        assert self._runtime is not None
        cdef lua_State* L = self._state
        lock_runtime(self._runtime)
        try:
            lua.lua_settop(L, 0)
            self.push_lua_object()
            return call_lua(self._runtime, L, args)
        finally:
            unlock_runtime(self._runtime)

    def __len__(self):
        assert self._runtime is not None
        cdef lua_State* L = self._state
        lock_runtime(self._runtime)
        try:
            self.push_lua_object()
            return lua.lua_objlen(L, -1)
        finally:
            lua.lua_settop(L, 0)
            unlock_runtime(self._runtime)

    def __nonzero__(self):
        return True

    def __iter__(self):
        raise TypeError("iteration is only supported for tables")

    def __repr__(self):
        assert self._runtime is not None
        cdef lua_State* L = self._state
        encoding = self._runtime._encoding.decode('ASCII') if self._runtime._encoding else 'UTF-8'
        lock_runtime(self._runtime)
        try:
            self.push_lua_object()
            return lua_object_repr(L, encoding)
        finally:
            lua.lua_pop(L, 1)
            unlock_runtime(self._runtime)

    def __str__(self):
        assert self._runtime is not None
        cdef lua_State* L = self._state
        cdef unicode py_string = None
        cdef const_char_ptr s
        encoding = self._runtime._encoding.decode('ASCII') if self._runtime._encoding else 'UTF-8'
        lock_runtime(self._runtime)
        try:
            self.push_lua_object()
            if lua.luaL_callmeta(L, -1, "__tostring"):
                s = lua.lua_tostring(L, -1)
                try:
                    if s:
                        try:
                            py_string = s.decode(encoding)
                        except UnicodeDecodeError:
                            # safe 'decode'
                            py_string = s.decode('ISO-8859-1')
                finally:
                    lua.lua_pop(L, 1)
            if py_string is None:
                py_string = lua_object_repr(L, encoding)
        finally:
            lua.lua_pop(L, 1)
            unlock_runtime(self._runtime)
        return py_string

    def __getattr__(self, name):
        assert self._runtime is not None
        cdef lua_State* L = self._state
        if isinstance(name, unicode):
            if (<unicode>name).startswith(u'__') and (<unicode>name).endswith(u'__'):
                return object.__getattr__(self, name)
            name = (<unicode>name).encode(self._runtime._source_encoding)
        elif isinstance(name, bytes) and (<bytes>name).startswith(b'__') and (<bytes>name).endswith(b'__'):
            return object.__getattr__(self, name)
        lock_runtime(self._runtime)
        try:
            self.push_lua_object()
            if lua.lua_isfunction(L, -1):
                lua.lua_pop(L, 1)
                raise TypeError("item/attribute access not supported on functions")
            py_to_lua(self._runtime, L, name, 0)
            lua.lua_gettable(L, -2)
            return py_from_lua(self._runtime, L, -1)
        finally:
            lua.lua_settop(L, 0)
            unlock_runtime(self._runtime)

    def __setattr__(self, name, value):
        assert self._runtime is not None
        cdef lua_State* L = self._state
        if isinstance(name, unicode):
            if (<unicode>name).startswith(u'__') and (<unicode>name).endswith(u'__'):
                object.__setattr__(self, name, value)
            name = (<unicode>name).encode(self._runtime._source_encoding)
        elif isinstance(name, bytes) and (<bytes>name).startswith(b'__') and (<bytes>name).endswith(b'__'):
            object.__setattr__(self, name, value)
        lock_runtime(self._runtime)
        try:
            self.push_lua_object()
            if not lua.lua_istable(L, -1):
                lua.lua_pop(L, -1)
                raise TypeError("Lua object is not a table")
            try:
                py_to_lua(self._runtime, L, name, 0)
                py_to_lua(self._runtime, L, value, 0)
                lua.lua_settable(L, -3)
            finally:
                lua.lua_settop(L, 0)
        finally:
            unlock_runtime(self._runtime)

    def __getitem__(self, index_or_name):
        return self.__getattr__(index_or_name)

    def __setitem__(self, index_or_name, value):
        self.__setattr__(index_or_name, value)


cdef _LuaObject new_lua_object(LuaRuntime runtime, lua_State* L, int n):
    cdef _LuaObject obj = _LuaObject.__new__(_LuaObject)
    init_lua_object(obj, runtime, L, n)
    return obj

cdef void init_lua_object(_LuaObject obj, LuaRuntime runtime, lua_State* L, int n):
    # additional INCREF to keep runtime from disappearing in GC runs
    cpython.ref.Py_INCREF(runtime)
    obj._runtime = runtime
    obj._state = L
    lua.lua_pushvalue(L, n)
    obj._ref = lua.luaL_ref(L, lua.LUA_REGISTRYINDEX)

cdef object lua_object_repr(lua_State* L, encoding):
    cdef bytes py_bytes
    lua_type = lua.lua_type(L, -1)
    if lua_type in (lua.LUA_TTABLE, lua.LUA_TFUNCTION):
        ptr = <void*>lua.lua_topointer(L, -1)
    elif lua_type in (lua.LUA_TUSERDATA, lua.LUA_TLIGHTUSERDATA):
        ptr = <void*>lua.lua_touserdata(L, -1)
    elif lua_type == lua.LUA_TTHREAD:
        ptr = <void*>lua.lua_tothread(L, -1)
    if ptr:
        py_bytes = cpython.bytes.PyBytes_FromFormat(
            "<Lua %s at %p>", lua.lua_typename(L, lua_type), ptr)
    else:
        py_bytes = cpython.bytes.PyBytes_FromFormat(
            "<Lua %s>", lua.lua_typename(L, lua_type))
    try:
        return py_bytes.decode(encoding)
    except UnicodeDecodeError:
        # safe 'decode'
        return py_bytes.decode('ISO-8859-1')


cdef class _LuaTable(_LuaObject):
    def __iter__(self):
        return _LuaIter(self, KEYS)

    def keys(self):
        """Returns an iterator over the keys of a table (or other
        iterable) that this object represents.  Same as iter(obj).
        """
        return _LuaIter(self, KEYS)

    def values(self):
        """Returns an iterator over the values of a table (or other
        iterable) that this object represents.
        """
        return _LuaIter(self, VALUES)

    def items(self):
        """Returns an iterator over the key-value pairs of a table (or
        other iterable) that this object represents.
        """
        return _LuaIter(self, ITEMS)

cdef _LuaTable new_lua_table(LuaRuntime runtime, lua_State* L, int n):
    cdef _LuaTable obj = _LuaTable.__new__(_LuaTable)
    init_lua_object(obj, runtime, L, n)
    return obj


cdef class _LuaFunction(_LuaObject):
    """A Lua function (which may become a coroutine).
    """
    def coroutine(self, *args):
        """Create a Lua coroutine from a Lua function and call it with
        the passed parameters to start it up.
        """
        assert self._runtime is not None
        cdef lua_State* L = self._state
        cdef lua_State* co
        cdef _LuaThread thread
        lock_runtime(self._runtime)
        try:
            self.push_lua_object()
            if not lua.lua_isfunction(L, -1) or lua.lua_iscfunction(L, -1):
                raise TypeError("Lua object is not a function")
            # create thread stack and push the function on it
            co = lua.lua_newthread(L)
            lua.lua_pushvalue(L, 1)
            lua.lua_xmove(L, co, 1)
            # create the coroutine object and initialise it
            assert lua.lua_isthread(L, -1)
            thread = new_lua_thread(self._runtime, L, -1)
            thread._arguments = args # always a tuple, not None !
            return thread
        finally:
            lua.lua_settop(L, 0)
            unlock_runtime(self._runtime)

cdef _LuaFunction new_lua_function(LuaRuntime runtime, lua_State* L, int n):
    cdef _LuaFunction obj = _LuaFunction.__new__(_LuaFunction)
    init_lua_object(obj, runtime, L, n)
    return obj


cdef class _LuaCoroutineFunction(_LuaFunction):
    """A function that returns a new coroutine when called.
    """
    def __call__(self, *args):
        return self.coroutine(*args)

cdef _LuaCoroutineFunction new_lua_coroutine_function(LuaRuntime runtime, lua_State* L, int n):
    cdef _LuaCoroutineFunction obj = _LuaCoroutineFunction.__new__(_LuaCoroutineFunction)
    init_lua_object(obj, runtime, L, n)
    return obj


cdef class _LuaThread(_LuaObject):
    """A Lua thread (coroutine).
    """
    cdef lua_State* _co_state
    cdef tuple _arguments
    def __iter__(self):
        return self

    def __next__(self):
        assert self._runtime is not None
        cdef tuple args = self._arguments
        if args is not None:
            self._arguments = None
        return resume_lua_thread(self, args)

    def send(self, value):
        """Send a value into the coroutine.  If the value is a tuple,
        send the unpacked elements.
        """
        if value is not None:
            if self._arguments is not None:
                raise TypeError("can't send non-None value to a just-started generator")
            if not isinstance(value, tuple):
                value = (value,)
        return resume_lua_thread(self, <tuple>value)

    def __bool__(self):
        cdef lua.lua_Debug dummy
        assert self._runtime is not None
        cdef int status = lua.lua_status(self._co_state)
        if status == lua.LUA_YIELD:
            return True
        if status == 0:
            # copied from Lua code: check for frames
            if lua.lua_getstack(self._co_state, 0, &dummy) > 0:
                return True # currently running
            elif lua.lua_gettop(self._co_state) > 0:
                return True # not started yet
        return False

cdef _LuaThread new_lua_thread(LuaRuntime runtime, lua_State* L, int n):
    cdef _LuaThread obj = _LuaThread.__new__(_LuaThread)
    init_lua_object(obj, runtime, L, n)
    obj._co_state = lua.lua_tothread(L, n)
    return obj


cdef _LuaObject new_lua_thread_or_function(LuaRuntime runtime, lua_State* L, int n):
    # this is special - we replace a new (unstarted) thread by its
    # underlying function to better follow Python's own generator
    # protocol
    cdef lua_State* co = lua.lua_tothread(L, n)
    assert co is not NULL
    if lua.lua_status(co) == 0 and lua.lua_gettop(co) == 1:
        # not started yet => get the function and return that
        lua.lua_pushvalue(co, 1)
        lua.lua_xmove(co, L, 1)
        try:
            return new_lua_coroutine_function(runtime, L, -1)
        finally:
            lua.lua_pop(L, 1)
    else:
        # already started => wrap the thread
        return new_lua_thread(runtime, L, n)


cdef object resume_lua_thread(_LuaThread thread, tuple args):
    cdef lua_State* co = thread._co_state
    cdef int result, i, nargs = 0
    if lua.lua_status(co) == 0 and lua.lua_gettop(co) == 0:
        # already terminated
        raise StopIteration
    lock_runtime(thread._runtime)
    try:
        if args:
            nargs = len(args)
            push_lua_arguments(thread._runtime, co, args)
        with nogil:
            result = lua.lua_resume(co, nargs)
        if result != lua.LUA_YIELD:
            if result == 0:
                # terminated
                if lua.lua_gettop(co) == 0:
                    # no values left to return
                    raise StopIteration
            else:
                raise_lua_error(co, result)
        return unpack_lua_results(thread._runtime, co)
    finally:
        lua.lua_settop(co, 0)
        unlock_runtime(thread._runtime)


cdef enum:
    KEYS = 1
    VALUES = 2
    ITEMS = 3

cdef class _LuaIter:
    cdef LuaRuntime _runtime
    cdef _LuaObject _obj
    cdef lua_State* _state
    cdef int _refiter
    cdef char _what

    def __cinit__(self, _LuaObject obj not None, int what):
        assert obj._runtime is not None
        self._runtime = obj._runtime
        # additional INCREF to keep object from disappearing in GC runs
        cpython.ref.Py_INCREF(obj)

        self._obj = obj
        self._state = obj._state
        self._refiter = 0
        self._what = what

    def __dealloc__(self):
        if self._runtime is None:
            return
        cdef lua_State* L = self._state
        if self._refiter:
            try:
                lock_runtime(self._runtime)
                locked = True
            except:
                locked = False
            lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, self._refiter)
            if locked:
                unlock_runtime(self._runtime)
        # undo additional INCREF at instantiation time
        cpython.ref.Py_DECREF(self._obj)

    def __repr__(self):
        return u"LuaIter(%r)" % (self._obj)

    def __iter__(self):
        return self

    def __next__(self):
        if self._obj is None:
            raise StopIteration
        cdef lua_State* L = self._obj._state
        lock_runtime(self._runtime)
        try:
            if self._obj is None:
                raise StopIteration
            # iterable object
            lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, self._obj._ref)
            if not lua.lua_istable(L, -1):
                if lua.lua_isnil(L, -1):
                    lua.lua_pop(L, 1)
                    raise LuaError("lost reference")
                raise TypeError("cannot iterate over non-table")
            if not self._refiter:
                # initial key
                lua.lua_pushnil(L)
            else:
                # last key
                lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, self._refiter)
            if lua.lua_next(L, -2):
                try:
                    if self._what == KEYS:
                        retval = py_from_lua(self._runtime, L, -2)
                    elif self._what == VALUES:
                        retval = py_from_lua(self._runtime, L, -1)
                    else: # ITEMS
                        retval = (py_from_lua(self._runtime, L, -2), py_from_lua(self._runtime, L, -1))
                finally:
                    # pop value
                    lua.lua_pop(L, 1)
                    # pop and store key
                    if not self._refiter:
                        self._refiter = lua.luaL_ref(L, lua.LUA_REGISTRYINDEX)
                    else:
                        lua.lua_rawseti(L, lua.LUA_REGISTRYINDEX, self._refiter)
                return retval
            elif self._refiter:
                lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, self._refiter)
            self._obj = None
        finally:
            unlock_runtime(self._runtime)
        raise StopIteration


cdef int py_asfunc_call(lua_State *L):
    lua.lua_pushvalue(L, lua.lua_upvalueindex(1))
    lua.lua_insert(L, 1)
    return py_object_call(L)


cdef object py_from_lua(LuaRuntime runtime, lua_State *L, int n):
    cdef size_t size
    cdef const_char_ptr s
    cdef lua.lua_Number number
    cdef py_object* py_obj
    cdef int lua_type = lua.lua_type(L, n)

    if lua_type == lua.LUA_TNIL:
        return None
    elif lua_type == lua.LUA_TNUMBER:
        number = lua.lua_tonumber(L, n)
        if number != <long>number:
            return <double>number
        else:
            return <long>number
    elif lua_type == lua.LUA_TSTRING:
        s = lua.lua_tolstring(L, n, &size)
        if runtime._encoding is not None:
            return s[:size].decode(runtime._encoding)
        else:
            return s[:size]
    elif lua_type == lua.LUA_TBOOLEAN:
        return lua.lua_toboolean(L, n)
    elif lua_type == lua.LUA_TUSERDATA:
        py_obj = <py_object*>lua.luaL_checkudata(L, n, POBJECT)
        if py_obj:
            return <object>py_obj.obj
    elif lua_type == lua.LUA_TTABLE:
        return new_lua_table(runtime, L, n)
    elif lua_type == lua.LUA_TTHREAD:
        return new_lua_thread_or_function(runtime, L, n)
    elif lua_type == lua.LUA_TFUNCTION:
        return new_lua_function(runtime, L, n)
    return new_lua_object(runtime, L, n)

cdef int py_to_lua(LuaRuntime runtime, lua_State *L, object o, bint withnone) except -1:
    cdef int pushed_values_count = 0
    cdef bint as_index = 0

    if o is None:
        if withnone:
            lua.lua_pushlstring(L, "Py_None", 7)
            lua.lua_rawget(L, lua.LUA_REGISTRYINDEX)
            if lua.lua_isnil(L, -1):
                lua.lua_pop(L, 1)
                lua.luaL_error(L, "lost none from registry")
        else:
            # Not really needed, but this way we may check for errors
            # with pushed_values_count == 0.
            lua.lua_pushnil(L)
            pushed_values_count = 1
    elif isinstance(o, bool):
        lua.lua_pushboolean(L, <bint>o)
        pushed_values_count = 1
    elif isinstance(o, (int, long, float)):
        lua.lua_pushnumber(L, <lua.lua_Number><double>o)
        pushed_values_count = 1
    elif isinstance(o, bytes):
        lua.lua_pushlstring(L, <char*>(<bytes>o), len(<bytes>o))
        pushed_values_count = 1
    elif isinstance(o, unicode) and runtime._encoding is not None:
        pushed_values_count = push_encoded_unicode_string(runtime, L, <unicode>o)
    elif isinstance(o, _LuaObject):
        if (<_LuaObject>o)._runtime is not runtime:
            raise LuaError("cannot mix objects from different Lua runtimes")
        lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, (<_LuaObject>o)._ref)
        pushed_values_count = 1
    else:
        as_index =  isinstance(o, (dict, list, tuple))
        pushed_values_count = py_to_lua_custom(runtime, L, o, as_index)
        if pushed_values_count and not as_index and hasattr(o, '__call__'):
            lua.lua_pushcclosure(L, <lua.lua_CFunction>py_asfunc_call, 1)
    return pushed_values_count

cdef int push_encoded_unicode_string(LuaRuntime runtime, lua_State *L, unicode ustring) except -1:
    cdef bytes bytes_string = ustring.encode(runtime._encoding)
    lua.lua_pushlstring(L, <char*>bytes_string, len(bytes_string))
    return 1

cdef bint py_to_lua_custom(LuaRuntime runtime, lua_State *L, object o, int as_index):
    cdef py_object *py_obj = <py_object*> lua.lua_newuserdata(L, sizeof(py_object))
    if py_obj:
        cpython.ref.Py_INCREF(o)
        cpython.ref.Py_INCREF(runtime)
        py_obj.obj = <PyObject*>o
        py_obj.runtime = <PyObject*>runtime
        py_obj.as_index = as_index
        lua.luaL_getmetatable(L, POBJECT)
        lua.lua_setmetatable(L, -2)
        return 1 # values pushed
    else:
        lua.luaL_error(L, "failed to allocate userdata object")
        return 0 # values pushed

cdef int raise_lua_error(lua_State* L, int result) except -1:
    if result == 0:
        return 0
    elif result == lua.LUA_ERRMEM:
        cpython.exc.PyErr_NoMemory()
    else:
        raise LuaError("error: %s" % lua.lua_tostring(L, -1))


cdef run_lua(LuaRuntime runtime, bytes lua_code):
    # locks the runtime
    cdef lua_State* L = runtime._state
    cdef bint result
    lock_runtime(runtime)
    try:
        if lua.luaL_loadbuffer(L, lua_code, len(lua_code), '<python>'):
            raise LuaError("error loading code: %s" % lua.lua_tostring(L, -1))
        return execute_lua_call(runtime, L, 0)
    finally:
        unlock_runtime(runtime)

cdef call_lua(LuaRuntime runtime, lua_State *L, tuple args):
    # does not lock the runtime!
    push_lua_arguments(runtime, L, args)
    return execute_lua_call(runtime, L, len(args))

cdef object execute_lua_call(LuaRuntime runtime, lua_State *L, Py_ssize_t nargs):
    cdef int result_status
    # call into Lua
    with nogil:
        result_status = lua.lua_pcall(L, nargs, lua.LUA_MULTRET, 0)
    try:
        runtime.reraise_on_exception()
        if result_status:
            raise_lua_error(L, result_status)
        return unpack_lua_results(runtime, L)
    finally:
        lua.lua_settop(L, 0)

cdef int push_lua_arguments(LuaRuntime runtime, lua_State *L, tuple args) except -1:
    cdef int i
    if args:
        for i, arg in enumerate(args):
            if not py_to_lua(runtime, L, arg, 0):
                lua.lua_settop(L, 0)
                raise TypeError("failed to convert argument at index %d" % i)
    return 0

cdef inline object unpack_lua_results(LuaRuntime runtime, lua_State *L):
    cdef int nargs = lua.lua_gettop(L)
    if nargs == 1:
        return py_from_lua(runtime, L, 1)
    if nargs == 0:
        return None
    return unpack_multiple_lua_results(runtime, L, nargs)

cdef tuple unpack_multiple_lua_results(LuaRuntime runtime, lua_State *L, int nargs):
    cdef tuple args = cpython.tuple.PyTuple_New(nargs)
    cdef int i
    for i in range(nargs):
        arg = py_from_lua(runtime, L, i+1)
        cpython.ref.Py_INCREF(arg)
        cpython.tuple.PyTuple_SET_ITEM(args, i, arg)
    return args


################################################################################
# Python support in Lua

# ref-counting support for Python objects

cdef void decref_with_gil(py_object *py_obj) with gil:
    cpython.ref.Py_XDECREF(py_obj.obj)
    cpython.ref.Py_XDECREF(py_obj.runtime)

cdef int py_object_gc(lua_State* L):
    cdef py_object *py_obj = <py_object*> lua.luaL_checkudata(L, 1, POBJECT)
    if py_obj is not NULL and py_obj.obj is not NULL:
        decref_with_gil(py_obj)
    return 0

# calling Python objects

cdef bint call_python(LuaRuntime runtime, lua_State *L, py_object* py_obj) except -1:
    cdef int i, nargs = lua.lua_gettop(L) - 1
    cdef bint ret = 0

    if not py_obj:
        lua.luaL_argerror(L, 1, "not a python object")
        return 0

    cdef tuple args = cpython.tuple.PyTuple_New(nargs)
    for i in range(nargs):
        arg = py_from_lua(runtime, L, i+2)
        cpython.ref.Py_INCREF(arg)
        cpython.tuple.PyTuple_SET_ITEM(args, i, arg)

    return py_to_lua(runtime, L, (<object>py_obj.obj)(*args), 0)

cdef int py_call_with_gil(lua_State* L, py_object *py_obj) with gil:
    cdef LuaRuntime runtime = None
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        return call_python(runtime, L, py_obj)
    except:
        runtime.store_raised_exception()
        try:
            message = (u"error during Python call: %r" % exc_info()[1]).encode('UTF-8')
            lua.luaL_error(L, message)
        except:
            lua.luaL_error(L, b"error during Python call")
        return 0

cdef int py_object_call(lua_State* L):
    cdef py_object *py_obj = <py_object*> lua.luaL_checkudata(L, 1, POBJECT)
    if not py_obj:
        lua.luaL_argerror(L, 1, "not a python object")
        return 0

    return py_call_with_gil(L, py_obj)

# str() support for Python objects

cdef int py_str_with_gil(lua_State* L, py_object* py_obj) with gil:
    cdef LuaRuntime runtime
    try:
        runtime = <LuaRuntime?>py_obj.runtime
        s = str(<object>py_obj.obj)
        if isinstance(s, unicode):
            s = (<unicode>s).encode(runtime._encoding)
        else:
            assert isinstance(s, bytes)
        lua.lua_pushlstring(L, <bytes>s, len(<bytes>s))
        return 1 # returning 1 value
    except:
        runtime.store_raised_exception()
        try:
            message = (u"error during Python str() call: %r" % exc_info()[1]).encode('UTF-8')
            lua.luaL_error(L, message)
        except:
            lua.luaL_error(L, b"error during Python str() call")
        return 0

cdef int py_object_str(lua_State* L):
    cdef py_object *py_obj = <py_object*> lua.luaL_checkudata(L, 1, POBJECT)
    if not py_obj:
        lua.luaL_argerror(L, 1, "not a python object")
        return 0
    return py_str_with_gil(L, py_obj)

# special methods for Lua

py_object_lib[0] = lua.luaL_Reg(name = "__gc",       func = <lua.lua_CFunction> py_object_gc)
py_object_lib[1] = lua.luaL_Reg(name = "__call",     func = <lua.lua_CFunction> py_object_call)
py_object_lib[2] = lua.luaL_Reg(name = "__tostring", func = <lua.lua_CFunction> py_object_str)
py_object_lib[3] = lua.luaL_Reg(name = NULL, func = NULL)

## # Python helper functions for Lua

## # empty for now
py_lib[0] = lua.luaL_Reg(name = NULL, func = NULL)

## static const luaL_reg py_object_lib[] = {
## 	{"__call",	py_object_call},
## 	{"__index",	py_object_index},
## 	{"__newindex",	py_object_newindex},
## 	{"__gc",	py_object_gc},
## 	{"__tostring",	py_object_tostring},
## 	{NULL, NULL}
## };

