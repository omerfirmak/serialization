/*******************************************************************************

    Function definition and helper related to serialization

    This module exposes two main categories of functions:
    - `serializeFull` / `serializePart` for serialization
    - `deserializeFull` for deserialization

    Any value type is natively supported and will just work, for serialization
    and deserialization. More complex types (arrays, struct, enums) are also
    supported natively. `class` are not supported by default, but there is
    a way for one to implement a custom serialization (or deserialization)
    policy, which can be used to make `class` serializable.

    Serializer_custom_hook:
    If an aggregate implements the serialization hook, it will be called
    directly instead of using the serializer's default.
    The method signature is defined as follows:
    ---
    struct Foo
    {
         void serialize (scope SerializeDg sink) const @safe;
    }
    ---
    The return type can be of another type, and other attributes
    (such as `pure`, `nothrow`, etc...) can be used and are encouraged.

    Deserializer_custom_hook:
    Similar to the serializer's custom hook, an aggregate can implement
    a method to handle deserialization manually.
    The method signature is defined as follows:
    ---
    struct Foo
    {
        static T fromBinary (T) (scope DeserializeDg data,
            in DeserializerOptions opts) @safe;
    }
    ---
    The deserializer might request an instance of a `const` or `immutable`
    object, hence `fromBinary` should not assume mutability.
    Also, as there is no way to call a static method with an attributed
    (e.g. `const`, `shared`, `immutable`) type, the template parameter
    is required. As for serialization, extra attributes (`pure`, etc...)
    are welcome and encouraged. A few implementation examples will follow.

    Memory_allocation:
    The serializer can be made non-allocating (e.g. by outputting to a buffer),
    although it currently can't be made `@nogc`.
    The deserializer, due to its abiliity to deserialize immutable data,
    and since the lifetime of the slice returned by `DeserializeDg` is not
    specified, should always allocate data.

    Unsigned_Integer:
    By default, unsigned integer types (`ushort`, `uint`, `ulong`) are
    encoded to a variable-length size.
    This means that encoding small unsigned values, such as length,
    won't take 8 bytes as it would on 64 bits systems, but just one byte.
    The encoding matches Bitcoin's scheme and can be disabled by providing
    `CompactMode.No` when serializing / deserializing.
    For more details see `toVarInt` and `fromVarInt` in this function.

    Resilience_and_length_deserialization:
    Since this module is potentially fed untrusted data, its safety should be
    reviewed with care. Custom deserialization methods should not assume the
    data is valid, not should they assume there is enough data left in the
    stream to complete the deserialization of the type.
    In particular, length deserialization can be dangerous, as feeding an
    unsanitized length to `new` could result in memory exhaustion.
    For this reason, the deserializer currently rejects length over `maxLength`,
    which can be configured via the second argument to `deserializeFull`
    (by default, `DeserializerOptions` allows for ~32k).
    This limit won't be enforced if a length is manually deserialized with
    `deserializeFull`, for example in a user-provided `fromBinary` hook.
    To deserialize length, use the `deserializeLength` function.

    Testing_data_types:
    `testSymmetry` is a convenient utility to test that a type can be
    properly serialized and later deserialized, without memory corruption or
    compilation error, by testing the type itself, its qualified variants,
    and its ability to be (de)serialized as array or nested in an aggregate.
    Refer to the function documentation for more details.

    Copyright:
        Copyright (c) 2019-2021 BOSAGORA Foundation
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.serialization.Serializer;

import std.algorithm;
import std.bitmanip;
import std.format;
import std.meta;
import std.range;
import std.traits;

/// Pedestrian usage of serialization
unittest
{
    struct SomeThing
    {
        ubyte[] some_bytes;
        string some_string;
        int negative_number;
        uint positive_number;
    }
    SomeThing thing = SomeThing([0x03, 0x02, 0x01], "321", -42, 42);
    // Serialize immutable data, then deserialize it as `const`
    ubyte[] thing_bytes = serializeFull(thing);
    assert(deserializeFull!(const(SomeThing))(thing_bytes) == thing);
    // A much better test for your own types is to do:
    testSymmetry(thing);

    // Internally, one could just concatenate two serialized items
    // The deserializer is driven by the data type it is asked for,
    // the data stream does not include any metadata
    ubyte[] thing_data = serializeFull(thing) ~ serializeFull(thing);

    void deserializeEntry () @safe
    {
        scope DeserializeDg dg = (size) @safe
        {
            scope(exit) thing_data = thing_data[size .. $];
            return thing_data[0 .. size];
        };

        const new_thing = deserializeFull!SomeThing(dg);
        assert(new_thing == thing);
    }

    deserializeEntry();
    deserializeEntry();

    // One can always implement their own policy
    // E.g. if for some reason you need to reorganize a struct's
    // field but need to keep the serialization the same
    static struct CustomPolicy
    {
        ubyte[] values;
        string s;
        uint i;

        void serialize (scope SerializeDg dg) const @safe
        {
            serializePart(this.values, dg);
            serializePart(this.i, dg);
            serializePart(this.s, dg);
        }

        static QT fromBinary (QT) (
            scope DeserializeDg dg, in DeserializerOptions opts)
            @safe
        {
            // One need to use temporary values for this,
            // as D currently does not support returning a struct literal
            // Additionally, https://issues.dlang.org/show_bug.cgi?id=20633
            auto values = deserializeFull!(typeof(QT.values))(dg, opts);
            auto i = deserializeFull!(typeof(QT.i))(dg, opts);
            auto s = deserializeFull!(typeof(QT.s))(dg, opts);
            return QT(values, s, i);
        }
    }

    auto custom = CustomPolicy([0x01, 0x02], "foo", 42);
    testSymmetry(custom);
}

/// Show some of the binary representation obtained by the serializer
unittest
{
    static struct Bar
    {
        ubyte u;
        long l;
    }
    static struct Foo
    {
        // A few basic types
        ubyte a;
        ushort b;
        uint c;
        ulong d;
        // An POD aggregate
        Bar e;
        // Mutable array
        ubyte[] f;
        // Signed data types are not encoded
        long g;
        // Immutable array
        string h;
    }
    const Foo instance = Foo(1, ushort.max, uint.max, ulong.max, Bar(42, 42), [1, 2, 3],
        42, "69");
    ubyte[] serialized = serializeFull(instance);

    assert(serialized == [
        1,                       // ubyte(1)     == 1 byte
        253,255, 255,            // ushort.max   == 3 bytes
        254, 255, 255, 255, 255, // uint.max     == 5 bytes
        255, 255, 255, 255, 255, 255, 255, 255, 255, // ulong.max == 9bytes
        42,                      // Bar: ubyte(1) == 1 byte
        0, 0, 0, 0, 0, 0, 0, 42, // Bar: long    == 8 bytes
        3, 1, 2, 3,              // ubyte[1,2,3] == 4 bytes
        0, 0, 0, 0, 0, 0, 0, 42, // long         == 8 bytes
        2, 54, 57]);             // string       == 1 byte length + 2 char bytes
    assert(serialized.deserializeFull!Foo() == instance);
}

/// Provides more details about `fromBinary` requirements
unittest
{
    static struct Example
    {
        ubyte[] data;

        public static QT fromBinary (QT) (
            scope DeserializeDg dg, in DeserializerOptions opts) @safe
        {
            // The following is incorrect because it doesn't account for
            // type constructors (e.g. `immutable`).
            // More precisely, it would trigger the following error:
            // ---
            // cannot implicitly convert expression
            // `deserializeFull(dg, DeserializerOptions.init)`
            // of type `ubyte[]` to `immutable(ubyte[])`
            // ---
            version (none)
                return QT(deserializeFull!(ubyte[])(dg, opts));

            // The following is the correct version
            return QT(deserializeFull!(typeof(QT.data))(dg, opts));
        }
    }

    ubyte[] data = [3, 1, 2, 3];
    scope DeserializeDg dg = (size) {
        scope (success) data = data[size .. $];
        return data[0 .. size];
    };

    immutable ex = Example([1, 2, 3]);
    assert(Example.fromBinary!(immutable(Example))(dg, DeserializerOptions.init)
           ==  ex);
}

/*******************************************************************************

    Sink for serialized data, writing to an underlying stream / buffer

    `SerializeDg` is guaranteed to make a copy of the data, so one need not
    keep around the value provided to it after it has returned.

*******************************************************************************/

public alias SerializeDg = void delegate(in ubyte[]) @safe;

/*******************************************************************************

    Input source for deserialized data

    This reads an `ubyte[]` stream from an underlying buffer or stream.
    The data can be modified as will, and will only be valid for the lifetime of
    the calling scope, or the same delegate is called again,
    whichever comes first. As a result, the caller should copy data it intends
    to keep.

*******************************************************************************/

public alias DeserializeDg = const(ubyte)[] delegate(size_t size) @safe;

/// Traits to check if a given type has a custom serialization routine
private enum hasSerializeMethod (T) = is(T == struct)
    && is(typeof(T.init.serialize(SerializeDg.init)));

/// Traits to check if a given type has a custom deserialization routine
private enum hasFromBinaryFunction (T) = is(T == struct)
    && is(typeof(&T.fromBinary!T));

/*******************************************************************************

    Convenience overload to `serializePart` which use a buffer

    This function takes a buffer as parameter, and will reset it before
    forwarding to `serializePart`. Is the buffer is large enough, and no
    custom `serialize` hook allocates, this function will not allocate.

    Params:
        T       = Top level type of data
        record  = Data to serialize
        buffer  = The buffer to reset then write to.
        compact = Whether integers are serialized in variable-length form

    Returns:
        A reference to `buffer` after serialization

*******************************************************************************/

public ubyte[] serializeToBuffer (T) (in T record, scope return ref ubyte[] buffer, CompactMode compact = CompactMode.Yes)
    @safe
{
    buffer.length = 0;
    () @trusted { assumeSafeAppend(buffer); }();
    scope SerializeDg dg = (in ubyte[] data) @safe
    {
        buffer ~= data;
    };
    serializePart(record, dg, compact);
    return buffer;
}

///
unittest
{
    static struct Bar
    {
        string val;
        int other;
        uint us;
    }

    Bar[3] arr = [
        Bar("Hello", 42, 82),
        Bar("Cruel", 420, 840),
        Bar("World", 2424, 100_000),
    ];

    ubyte[] buffer = new ubyte[512];
    auto ret1 = serializeToBuffer(arr, buffer);
    assert(ret1.length ==
                1 /* Top level array length */ +
                "HelloCruelWorld".length +
                3 /* length of string encoded as a single byte */ +
                5 /* 42 encoded as 4 bytes, 82 encoded as a single byte */ +
                6 /* 420 as 4 bytes, 840 as 2 bytes */ +
                9 /* 2424 as 4 bytes, 100k as 5 bytes */);
    assert(ret1.ptr is buffer.ptr);
}

/*******************************************************************************

    Serialize a type and returns it as binary data.

    This function allocates and should be seldom used.
    Prefer its delegate or buffer variant, `serializePart`.

    Params:
        T       = Top level type of data
        record  = Data to serialize
        dg      = Serialization delegate (equivalent to an output range)
        compact = Whether integers are serialized in variable-length form

    Returns:
        The serialized `ubyte[]`

*******************************************************************************/

public ubyte[] serializeFull (T) (in T record, CompactMode compact = CompactMode.Yes)
    @safe
{
    ubyte[] buffer;
    return serializeToBuffer(record, buffer, compact);
}

///
unittest
{
    static struct Foo
    {
        const(ubyte)[] bar;
    }

    const(Foo)[] arr = [
        { bar: [ 6, 5, 4,  3, 2, 1, 0 ], },
        { bar: [ 9, 8, 7,  0], },
        { bar: [ 4, 4, 4,  4], },
        { bar: [ 2, 4, 8, 16], },
        { bar: [ 0, 1, 2,  4], },
    ];
    immutable ubyte[] result = [
        5,                   // arr.length
        7,                   // arr[0].bar.length
        6, 5, 4, 3, 2, 1, 0, // arr[0].bar
        4,                   // arr[1].bar.length
        9, 8, 7, 0,          // arr[1].bar
        4,                   // arr[2].bar.length
        4, 4, 4, 4,          // arr[2].bar
        4,                   // arr[3].bar.length
        2, 4, 8, 16,         // arr[3].bar
        4,                   // arr[4].bar.length
        0, 1, 2, 4,          // arr[4].bar
    ];

    assert(arr.serializeFull() == result);

    testSymmetry!Foo();
    testSymmetry(arr);
}

/// Ditto
public void serializePart (T) (in T record, scope SerializeDg dg,
                               CompactMode compact = CompactMode.Yes)
    @safe
{
    // Custom serialization handling trumps everything else
    static if (hasSerializeMethod!T)
        record.serialize(dg);

    // Static array needs to be handled before arrays (because they convert)
    else static if (is(T : E[N], E, size_t N))
    {
        // Small type optimization
        static if (!hasSerializeMethod!E && (E.sizeof == 1 || isSomeChar!E))
            dg(cast(const(ubyte[]))record);
        else
            foreach (ref elem; record)
                serializePart(elem, dg, compact);
    }

    // Strings can be encoded as binary data
    else static if (isNarrowString!T)
    {
        toVarInt(record.length, dg);
        dg(cast(const(ubyte[]))record);
    }

    // If it's binary data, just copy it
    else static if (is(immutable(T) == immutable(ubyte[])))
    {
        toVarInt(record.length, dg);
        dg(record);
    }

    // If there's not fast path for array optimization, just recurse
    else static if (is(T : E[], E))
    {
        toVarInt(record.length, dg);
        foreach (const ref entry; record)
            entry.serializePart(dg, compact);
    }

    // Pointers are handled as arrays, only their size must be 0 or 1
    else static if (is(T : E*, E))
    {
        if (record is null)
            toVarInt(uint(0), dg);
        else
        {
            toVarInt(uint(1), dg);
            serializePart(*record, dg, compact);
        }
    }

    // Enum are never compact-serialized by default
    else static if (is(T == enum))
        serializePart!(OriginalType!T)(record, dg, CompactMode.No);

    // Unsigned integer may be encoded (e.g. sizes)
    // However `ubyte` doesn't need binary encoding since they it already is the
    // smallest possible size
    else static if (is(Unqual!T == ubyte))
        () @trusted { dg((&record)[0 .. T.sizeof]); }();
    else static if (isUnsigned!T)
    {
        if (compact == CompactMode.Yes)
            toVarInt(record, dg);
        else
            () @trusted { dg(nativeToBigEndian(record)[0 .. T.sizeof]); }();
    }
    // Other integers / scalars
    else static if (isScalarType!T)
       () @trusted { dg(nativeToBigEndian(record)[0 .. T.sizeof]); }();

    // Recursively serialize fields for structs
    else static if (is(T == struct))
        foreach (const ref field; record.tupleof)
            serializePart(field, dg, compact);

    else
        static assert(0, "Unhandled type: " ~ T.stringof);
}

unittest
{
    static struct Record { ulong a; }
    ubyte[][2] stores;
    serializePart(Record(42), (in ubyte[] arg) { stores[0] ~= arg; }, CompactMode.No);
    serializePart(ulong(42),  (in ubyte[] arg) { stores[1] ~= arg; }, CompactMode.No);
    assert(stores[0] == stores[1]);
}

/// Whether integers are serialized in variable-length form
public enum CompactMode : bool
{
    No,
    Yes
}

/// Options that configure the behavior of the deserializer
public struct DeserializerOptions
{
    /// The bound to apply to a length deserialization (e.g. for arrays)
    public size_t maxLength = DefaultMaxLength;

    /// Whether or not to use compact notation for unsigned integer
    public CompactMode compact = CompactMode.Yes;
}

/*******************************************************************************

    Default upper bound for `deserializeLength` and friends

    The value is set to a bit less than eight full pages on most systems,
    and allows to have allocations taking a full page,
    as the GC puts some metadata on each page.

*******************************************************************************/

public enum DefaultMaxLength = 0x79D0;

/*******************************************************************************

    Deserialize a length, checks if it's within reasonable bound, and return it

    This is a convenience function that calls `deserializeFull`, and checks
    the result matches a certain bound.

    It is used everywhere an array is deserialized, for example to prevent
    a DoS if we received crafted binary data that would lead us to allocates
    large amounts of memory, either exceeding our available memory,
    or overloading the GC.

    Params:
        dg         = Delegate to read binary data for deserialization
        upperBound = The value of the upper bound (inclusive).
                     Default to `DefaultMaxLength`.


    Throws:
        if the length is > to `upperBound`

    Returns:
        The deserialized length

*******************************************************************************/

public size_t deserializeLength (
    scope DeserializeDg dg, size_t upperBound = DefaultMaxLength)
    @safe
{
    size_t len = deserializeFull!size_t(dg);
    if (len > upperBound)
        throw new Exception(format("Value of 'length' exceeds upper bound (%d > %d)", len, upperBound));
    return len;
}

/*******************************************************************************

    Deserialize a data type and return it

    Params:
        T = Type of data to deserialize
        data = Binary serialized representation of `T` to be deserialized
        dg   = Delegate to read binary data for deserialization
        opts = Deserialization options (see the type's documentation for a list)

    Returns:
        The deserialized data type

*******************************************************************************/

public T deserializeFull (T) (scope const(ubyte)[] data,
    in DeserializerOptions opts = DeserializerOptions.init) @safe
{
    scope DeserializeDg dg = (size) @safe
    {
        if (size > data.length)
            throw new Exception(
                format("Requested %d bytes but only %d bytes available", size, data.length));

        auto res = data[0 .. size];
        data = data[size .. $];
        return res;
    };
    return deserializeFull!T(dg, opts);
}

/// Ditto
public T deserializeFull (T) (scope DeserializeDg dg,
    in DeserializerOptions opts = DeserializerOptions.init) @safe
{
    // Custom deserialization trumps everything
    static if (hasFromBinaryFunction!T)
        return T.fromBinary!T(dg, opts);

    // Static array needs to be handled before arrays
    else static if (is(T : E[N], E, size_t N))
    {
        static if (!hasFromBinaryFunction!E && (isSomeChar!E || E.sizeof == 1))
            return (() @trusted { return (cast(E[]) dg(E.sizeof * N)); })()[0 .. N];
        // Note: This does not allocate because `staticMap` yields a tuple
        else
        {
            E deserializeEntry () ()
            {
                return deserializeFull!E(dg, opts);
            }
            return [ Repeat!(N, deserializeEntry) ];
        }
    }

    // Validate strings as they are supposed to be UTF-8 encoded
    else static if (isNarrowString!T)
    {
        alias E = ElementEncodingType!T;
        size_t length = deserializeLength(dg, opts.maxLength);
        T process () @trusted
        {
            import std.utf;
            auto record = cast(E[]) (dg(E.sizeof * length));
            record.validate();
            return record;
        }
        return process().dup;
    }

    // If it's binary data, just copy it
    else static if (is(immutable(T) == immutable(ubyte[])))
    {
        size_t length = deserializeLength(dg, opts.maxLength);
        return dg(ubyte.sizeof * length).dup;
    }

    // Array deserialization
    else static if (is(T : E[], E))
    {
        size_t length = deserializeLength(dg, opts.maxLength);
        return iota(length).map!(_ => dg.deserializeFull!(ElementType!T)(opts)).array();
    }

    // Pointers are handled as arrays, only their size must be 0 or 1
    else static if (is(T : E*, E))
    {
        if (ubyte len = deserializeFull!ubyte(dg, opts))
        {
            if (len != 1)
                throw new Exception(format("Pointer expected to have length of 0 or 1, got: %d", len));
            return &[ deserializeFull!(typeof(T.init[0]))(dg, opts) ][0];
        }
        return T.init;
    }

    // Enum deserialize as their base type
    else static if (is(T == enum))
    {
        // https://github.com/bosagora/serialization/issues/9
        return cast(T) deserializeFull!(OriginalType!T)(
            dg, DeserializerOptions(opts.maxLength, CompactMode.No));
    }

    // 'bool' need to be converted explicitly
    else static if (is(Unqual!T == bool))
        return !!dg(T.sizeof)[0];

    // Possibly encoding integer
    else static if (isUnsigned!T)
    {
        // `ubyte` don't need binary encoding since they are already the
        // smallest possible size
        static if (is(Unqual!T == ubyte))
            return dg(ubyte.sizeof)[0];
        else
        {
            if (opts.compact == CompactMode.Yes)
                return deserializeVarInt!T(dg);
            else
                return () @trusted { return bigEndianToNative!(T)(*cast(ubyte[T.sizeof]*)(dg(T.sizeof).ptr)); }();
        }
    }

    // Other integers / scalars
    else static if (isScalarType!T)
        return () @trusted { return bigEndianToNative!(T)(*cast(ubyte[T.sizeof]*)(dg(T.sizeof).ptr)); }();

    // Default to per-field deserialization for struct
    else static if (is(T == struct))
    {
        Target convert (Target) ()
        {
            return deserializeFull!Target(dg, opts);
        }
        return T(staticMap!(convert, Fields!T));
    }

    else
        static assert(0, "Unhandled type: " ~ T.stringof);
}

// Serialization: Make sure we always serialize in little-endian format
unittest
{
    // To test this, we need to encode something which length > 1.
    // Since we sometimes encode integers using a compact mode,
    // we need to test both with and without compact mode.
    // When using compact mode, the value used needs to be > 0xFC (252)
    // otherwise it'll be serialized in a single byte.

    const ushort[] array = [ 0, ushort.max / 2, 0xFF ];
    // ushort.max / 2 = 32767: 0b01111111_11111111 => 127, 255
    assert(array.serializeFull() == [ 3, 0, 0xFD, 127, 255, 0xFD, 0, 0xFF ]);

    static struct S
    {
        uint[] arr = [ 0, ushort.max / 2, 0xFF ];
    }
    assert(S.init.serializeFull() == [3, 0, 0xFD, 127, 255, 0xFD, 0, 0xFF ]);


    const uint[] array2 = [ 0xF000_FFFF, 0xFFFF_0000 ];
    assert(array2.serializeFull(CompactMode.No) ==
           [ 2, 0xF0, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00 ]);

    static struct S2
    {
        uint[] arr = [ 0xF000_FFFF, 0xFFFF_0000 ];
    }
    assert(S2.init.serializeFull(CompactMode.No) ==
           [2, 0xF0, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00 ]);

}

// Make sure BitBlobs are serialized without length
unittest
{
    import geod24.bitblob;

    alias Hash = BitBlob!512;
    testSymmetry!Hash();

    Hash val;
    ubyte[] serialized = val.serializeFull();
    assert(serialized.length == Hash.sizeof);
    assert(serialized == (ubyte[64]).init);

    serialized[$/2] = 0xFF;
    assert(serialized.deserializeFull!Hash() == Hash(
        `0x00000000000000000000000000000000000000000000000000000000000000FF`
        ~ `0000000000000000000000000000000000000000000000000000000000000000`));
}

// Deserialization: Test for invalid string
unittest
{
    import std.exception;
    import std.utf;
    ubyte[] data = [3, 167, 133, 175];
    assertThrown!UTFException(data.deserializeFull!string);
}

// Deserialization: Test for out of bound length
unittest
{
    import std.exception;

    static struct Bomb { ubyte[] data; }
    ubyte[16192] bomb;
    bomb[0] = 0xFD;
    bomb[1] = 0xFF;
    bomb[2] = 0xFF;
    assertThrown!(Exception)(deserializeFull!Bomb(bomb));
}

// Test for pointers
unittest
{
    struct Bar
    {
        ushort a;
        string s;
    }
    Bar goodBar = Bar(10, "beers");
    static struct OptionalHash
    {
        uint a;
        const(Bar)* perhaps;
        string name;

        // Need those for `testSymmetry`, other it compares pointer values
        public bool opEquals (ref const OptionalHash o) const
            pure @nogc nothrow @safe
        {
            return this.a == o.a &&
                !(!!this.perhaps ^ !!o.perhaps) &&
                (this.perhaps is null || *this.perhaps == *o.perhaps) &&
                this.name == o.name;
        }
    }

    testSymmetry!OptionalHash();
    testSymmetry(OptionalHash(42, &goodBar, "Baguettes are good"));
    testSymmetry(OptionalHash(24, null, "Good, Baguettes are"));
}

/// Test for static arrays
unittest
{
    static struct Container
    {
        uint[4] data;
        char[2] chs;
    }

    static struct Container2
    {
        Container[4] data;
    }

    testSymmetry!Container();
    testSymmetry!Container2();

    Container2 c = {
        data: [ {[ 1, 2, 3, 4 ], [ 'a', 'b' ]}, {[ 5, 6, 7, 8 ], [ 'c', 'd' ]},
                {[ 9, 10, 11, 12 ], [ 'e', 'f' ]}, {[ 13, 14, 15, 16 ], [ 'g', 'h' ]} ]
    };

    testSymmetry(c.data[0]);
    testSymmetry(c.data[1]);
    testSymmetry(c.data[2]);
    testSymmetry(c.data[3]);
    testSymmetry(c);

    // Check that no allocation is performed
    auto serialized = serializeFull(c);

    const res = deserializeFull!Container2(serialized);
    assert(res == c);
}

/*******************************************************************************

    Encode an unsigned integer to its variable-length binary format

    VarInt Size
    size <= 0xFC(252)  -- 1 byte   ubyte
    size <= USHORT_MAX -- 3 bytes  (0xFD + ushort)
    size <= UINT_MAX   -- 5 bytes  (0xFE + uint)
    size <= ULONG_MAX  -- 9 bytes  (0xFF + ulong)

    Params:
        T = Type of unsigned integer to serialize
        var = Instance of `T` to serialize
        dg  = Serialization delegate

    Returns:
        The serialized convert variable length integer

*******************************************************************************/

private void toVarInt (T) (in T var, scope SerializeDg dg) @trusted
    if (isUnsigned!T)
{
    assert(var >= 0);
    static immutable ubyte[] type = [0xFD, 0xFE, 0xFF];
    if (var <= 0xFC)
        dg((cast(ubyte*)&(*cast(ubyte*)&var))[0 .. 1]);
    else if (var <= ushort.max)
    {
        dg(type[0..1]);
        dg(nativeToBigEndian(cast(ushort) var)[0 .. ushort.sizeof]);
    }
    else if (var <= uint.max)
    {
        dg(type[1..2]);
        dg(nativeToBigEndian(cast(uint) var)[0 .. uint.sizeof]);
    }
    else if (var <= ulong.max)
    {
        dg(type[2..3]);
        dg(nativeToBigEndian!ulong(var)[0 .. ulong.sizeof]);
    }
    else
        assert(0);
}

/// For varint
unittest
{
    ubyte[] res;
    scope SerializeDg dg = (in ubyte[] data)
    {
        res ~= data;
    };
    toVarInt(ulong.init, dg);
    assert(res == [0x00]);
    res.length = 0;
    toVarInt(252uL, dg);
    assert(res == [0xFC]);
    res.length = 0;
    toVarInt(253uL, dg);
    assert(res == [0xFD, 0x00, 0xFD]);
    res.length = 0;
    toVarInt(255uL, dg);
    assert(res == [0xFD, 0x00, 0xFF]);
    res.length = 0;
    toVarInt(ushort.max, dg);
    assert(res == [0xFD, 0xFF, 0xFF]);
    res.length = 0;
    toVarInt(0x10000u, dg);
    assert(res == [0xFE, 0x00, 0x01, 0x00, 0x00]);
    res.length = 0;
    toVarInt(uint.max, dg);
    assert(res == [0xFE, 0xFF, 0xFF, 0xFF, 0xFF]);
    res.length = 0;
    toVarInt(0x100000000u, dg);
    assert(res == [0xFF, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]);
    res.length = 0;
    toVarInt(ulong.max, dg);
    assert(res == [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
}

/*******************************************************************************

    Deserialize an integer of variable length using Bitcoin-style encoding

    VarInt Size
    size_tag is first a ubyte
    size_tag <= 0xFC(252)  -- 1 byte   ubyte
    size_tag == 0xFD       -- 3 bytes  (0xFD + ushort)
    size_tag == 0xFE       -- 5 bytes  (0xFE + uint)
    size_tag == 0xFF       -- 9 bytes  (0xFF + ulong)

    Params:
        T = Type of unsigned integer to deserialize
        dg = source of binary data

    Returns:
      The deserialized value, typed as `T`

    Throws:
      If the deserialized value does not fit into a `T`.
      Note that for `ulong`, this function is `nothrow`.

    See_Also: https://learnmeabitcoin.com/glossary/varint

*******************************************************************************/

private T deserializeVarInt (T) (scope DeserializeDg dg)
    @safe
    if (is(Unqual!T == ushort) || is(Unqual!T == uint) || is(Unqual!T == ulong))
{
    const ubyte int_size = dg(ubyte.sizeof)[0];

    T read (InType)() @trusted
    {
        import std.exception;
        auto value = bigEndianToNative!(InType)(*cast(ubyte[InType.sizeof]*)(dg(InType.sizeof).ptr));
        static if (T.max < InType.max)
            enforce(value <= T.max);
        return cast(T)value;
    }

    if (int_size <= 0xFC)
        return cast(T)(int_size);
    else if (int_size == 0xFD)
        return read!ushort();
    else if (int_size == 0xFE)
        return read!uint();
    else
    {
        assert(int_size == 0xFF);
        return read!ulong();
    }
}

/// For varint
unittest
{
    ubyte[] data = [
        0x00,                           // ulong.init
        0xFC,                           // ulong(0xFC) == 1 byte
        0xFD, 0x00, 0xFD,               // ulong(0xFD) == 3 bytes
        0xFD, 0x00, 0xFF,               // ulong(0xFE) == 3 bytes
        0xFD, 0xFF, 0xFF,               // ushort.max == 3 bytes
        0xFE, 0x00, 0x01, 0x00, 0x00,   // 0x10000u   == 5 bytes
        0xFE, 0xFF, 0xFF, 0xFF, 0xFF,   // uint.max   == 5 bytes
        // 0x100000000u == 9bytes
        0xFF, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
        // ulong.max == 9bytes
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];

    static struct Foo
    {
        ulong a;
        ulong b;
        ulong c;
        ulong d;
        ushort e;
        uint f;
        uint g;
        ulong h;
        ulong i;
    }
    assert(deserializeFull!Foo(data) == Foo(ulong.init, 252uL, 253uL, 255uL,
        ushort.max, 0x10000u, uint.max, 0x100000000u, ulong.max));
}

// Unittest-only utility functions
version(unittest):

/*******************************************************************************

    Test the symmetry of a type

    The provided type will be serialized, then deserialized, and tested for
    equality. If a mismatch happens, a verbose error message will be issued.

    If no argument is provided, the `init` value will be tested.

    This function also tests that a `struct` containing `T`, an array of `T`,
    and a struct containing an array of `T` can be properly serialized.

*******************************************************************************/

public void testSymmetry (T) (auto ref T value = T.init)
{
    testSymmetryImpl(value, T.stringof);

    T[] arr = [ value, T.init, value, T.init ];
    testSymmetryImpl(arr, "array of " ~ T.stringof);

    static struct Container { T val; }
    testSymmetryImpl(Container(value), "struct containing a " ~ T.stringof);

    static struct ContainerArray { T[] val; }
    testSymmetryImpl(ContainerArray(arr), "struct containing an array of " ~ T.stringof);
}

/// Ditto
private void testSymmetryImpl (T) (in T value, string typename)
{
    import std.stdio;

    ubyte[] serialized;
    {
        scope(failure) stderr.writeln("Serialization of ", typename, " failed!");
        serialized = value.serializeFull();
    }
    assert(serialized.length, T.stringof ~ " did not serialize to anything?");
    {
        bool testing = false;
        scope(failure)
            if (!testing)
            {
                stderr.writeln("Deserialization of ", typename, " failed. Binary data:");
                stderr.writeln(serialized);
            }
        const deserialized = serialized.deserializeFull!(T)();
        testing = true;
        assert(deserialized == value,
               format("Serialization mismatch for %s! Expected:\n%s\n\ngot:\n%s\n\nBinary data:\n%s",
                      typename, value, deserialized, serialized));
    }
}

/*******************************************************************************

    Tests that a `fromBinary` function compiles correctly

    Since the deserializer uses `fromBinary` only if it matches the definition
    it expects, to avoid accidentally matching `fromBinary` methods not intended
    for it, a mistake in `fromBinary` will just use the default for the type,
    most likely the constructor call with `tupleof` as member.

    This function is a convenient way to test that a type's `fromBinary`
    compiles, and hence is useful during development.
    If the `fromBinary` doesn't compile, error messages will be displayed.

    Params:
      T = The unqualified (non-`const`, non-`immutable`) type to test.

*******************************************************************************/

public void checkFromBinary (T) ()
{
    DeserializeDg dg;
    DeserializerOptions opts;
    bool b;
    if (b)
    {
        T i1            = T.fromBinary!(T)(dg, opts);
        const(T) i2     = T.fromBinary!(const T)(dg, opts);
        immutable(T) i3 = T.fromBinary!(immutable T)(dg, opts);
    }
}

// https://github.com/bosagora/serialization/issues/9
unittest
{
    enum QTYPE : ushort { A = 1, ALL = 255, }
    auto serialized = serializeFull(QTYPE.A);
    assert(serialized == [ 0, 1 ]);
    assert(deserializeFull!QTYPE(serialized) == QTYPE.A);
}
