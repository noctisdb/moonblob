-- @class BlobWriter
ffi = require('ffi')
band, bnot, shr = bit.band, bit.bnot, bit.rshift

local _native, _byteOrder, _parseByteOrder
local _tags, _getTag, _taggedReaders, _taggedWriters, _packMap, _unpackMap

--- Writes binary data to memory.
class BlobWriter
	--- Creates a new BlobWriter instance.
	--
	-- @tparam[opt] string byteOrder Byte order
	--
	-- Use `le` or `<` for little endian; `be` or `>` for big endian; `host`, `=` or `nil` to use the
	-- host's native byteOrder (default)
	--
	-- @tparam[opt] number size The initial size of the blob. Default size is 1024. Will grow automatically when needed.
	-- @treturn BlobWriter A new BlobWriter instance.
	-- @usage writer = BlobWriter!
	-- @usage writer = BlobWriter('<', 1000)
	new: (byteOrder, size) =>
		@_length, @_size = 0, 0
		@setByteOrder(byteOrder)
		@_allocate(size or 1024)

	--- Sets the order in which multi-byte values will be written.
	--
	-- @tparam string byteOrder Byte order
	--
	-- Can be either `le` or `<` for little endian, `be` or `>` for big endian, or `host` or `nil` for native host byte
	-- order.
	--
	-- @treturn BlobWriter self
	setByteOrder: (byteOrder) =>
		@_orderBytes = _byteOrder[_parseByteOrder(byteOrder)]
		@

	--- Writes a value to the output buffer. Determines the type of the value automatically.
	--
	-- Supported value types are `number`, `string`, `boolean` and `table`.
	-- @param value the value to write to the output buffer
	-- @treturn BlobWriter self
	write: (value) => @_writeTagged(value)

	--- Writes a Lua number to the output buffer.
	--
	-- @tparam number number The number to write to the output buffer
	-- @treturn BlobWriter self
	number: (number) =>
		_native.n = number
		@u32(_native.u32[0])\u32(_native.u32[1])

	--- Writes a boolean value to the output buffer.
	--
	-- The value is written as an unsigned 8 bit value (`true = 1`, `false = 0`)
	-- @tparam bool bool The boolean value to write to the output buffer
	--
	-- @treturn BlobWriter self
	bool: (bool) => @u8(bool and 1 or 0)

	--- Writes a string to the output buffer.
	--
	-- Stores the length of the string as a `vu32` field before the actual string data.
	-- @tparam string str The string to write to the output buffer
	-- @treturn BlobWriter self
	string: (str) =>
		length = #str
		@vu32(length)\raw(str, length)

	--- Writes an unsigned 8 bit value to the output buffer.
	--
	-- @tparam number u8 The value to write to the output buffer
	-- @treturn BlobWriter self
	u8: (u8) =>
		@_grow(1) if @_length + 1 > @_size
		@_data[@_length] = u8
		@_length += 1
		@

	--- Writes a signed 8 bit value to the output buffer.
	--
	-- @tparam number s8 The value to write to the output buffer
	-- @treturn BlobWriter self
	s8: (s8) =>
		_native.s8[0] = s8
		@u8(_native.u8[0])

	--- Writes an unsigned 16 bit value to the output buffer.
	--
	-- @tparam number u16 The value to write to the output buffer
	-- @treturn BlobWriter self
	u16: (u16) =>
		len = @_length
		@_grow(2) if len + 2 > @_size
		b1, b2 = @_orderBytes(band(u16, 2 ^ 8 - 1), shr(u16, 8))
		@_data[len], @_data[len + 1] = b1, b2
		@_length += 2
		@

	--- Writes a signed 16 bit value to the output buffer.
	--
	-- @tparam number s16 The value to write to the output buffer
	-- @treturn BlobWriter self
	s16: (s16) =>
		_native.s16[0] = s16
		@u16(_native.u16[0])

	--- Writes an unsigned 32 bit value to the output buffer.
	--
	-- @tparam number u32 The value to write to the output buffer
	-- @treturn BlobWriter self
	u32: (u32) =>
		len = @_length
		@_grow(4) if len + 4 > @_size
		w1, w2 = @_orderBytes(band(u32, 2 ^ 16 - 1), shr(u32, 16))
		b1, b2 = @_orderBytes(band(w1, 2 ^ 8 - 1), shr(w1, 8))
		b3, b4 = @_orderBytes(band(w2, 2 ^ 8 - 1), shr(w2, 8))
		@_data[len], @_data[len + 1], @_data[len + 2], @_data[len + 3] = b1, b2, b3, b4
		@_length += 4
		@

	--- Writes a signed 32 bit value to the output buffer.
	--
	-- @tparam number s32 The value to write to the output buffer
	-- @treturn BlobWriter self
	s32: (s32) =>
		_native.s32[0] = s32
		@u32(_native.u32[0])

	--- Writes an unsigned 64 bit value to the output buffer.
	--
	-- Lua numbers are only accurate for values < 2 ^ 53. Use the LuaJIT `ULL` suffix to write large numbers.
	-- @usage writer\u64(72057594037927936ULL)
	-- @tparam number u64 The value to write to the output buffer
	-- @treturn BlobWriter self
	u64: (u64) =>
		_native.u64 = u64
		a, b = @_orderBytes(_native.u32[0], _native.u32[1])
		@u32(a)\u32(b)

	--- Writes a signed 64 bit value to the output buffer.
	--
	-- @see BlobWriter:u64
	-- @tparam number s64 The value to write to the output buffer
	-- @treturn BlobWriter self
	s64: (s64) =>
		_native.s64 = s64
		a, b = @_orderBytes(_native.u32[0], _native.u32[1])
		@u32(a)\u32(b)

	--- Writes a 32 bit floating point value to the output buffer.
	--
	-- @tparam number f32 The value to write to the output buffer
	-- @treturn BlobWriter self
	f32: (f32) =>
		_native.f[0] = f32
		@u32(_native.u32[0])

	--- Writes a 64 bit floating point value to the output buffer.
	---
	-- @tparam number f64 The value to write to the output buffer
	-- @treturn BlobWriter self
	f64: (f64) => @number(f64)

	--- Writes raw binary data to the output buffer.
	--
	-- @tparam string|cdata raw A `string` or `cdata` with the data to write to the output buffer
	-- @tparam[opt] number length Length of data (not required when data is a string)
	-- @treturn BlobWriter self
	raw: (raw, length) =>
		length = length or #raw
		makeRoom = (@_size - @_length) - length
		@_grow(math.abs(makeRoom)) if makeRoom < 0
		ffi.copy(ffi.cast('char*', @_data + @_length), raw, length)
		@_length += length
		@

	--- Writes a string to the output buffer, followed by a null byte.
	--
	-- @tparam string str The string to write to the output buffer
	-- @treturn BlobWriter self
	cstring: (str) => @raw(str)\u8(0)

	--- Writes a table to the output buffer.
	--
	-- Supported field types are number, string, bool and table. Cyclic references throw an error.
	-- @tparam table t The table to write to the output buffer
	-- @treturn BlobWriter self
	table: (t) => @_writeTable(t, {})

	--- Writes an unsigned 32 bit integer value with varying length.
	--
	-- The value is written in an encoded format. The length depends on the value; larger values need more space.
	-- The minimum length is 1 byte for values < 2^7, maximum length is 5 bytes for values >= 2^28.
	-- @tparam number value The unsigned integer value to write to the output buffer
	-- @see BlobWriter:vu32size
	-- @treturn BlobWriter self
	vu32: (value) =>
		assert(value < 2 ^ 32, "Exceeded u32 value range")

		for i = 7, 28, 7
			mask, shift = 2 ^ i - 1, i - 7
			return @u8(shr(band(value, mask), shift)) if value < 2 ^ i
			@u8(shr(band(value, mask), shift) + 0x80)
		@u8(shr(band(value, 0xf0000000), 28))

	--- Writes a signed 32 bit integer value with varying length.
	--
	-- @tparam number value The signed integer value to write to the output buffer
	-- @see BlobWriter:vu32
	-- @treturn BlobWriter self
	vs32: (value) =>
		assert(value < 2 ^ 31 and value >= -2^31, "Exceeded s32 value range")
		_native.s32[0] = value
		@vu32(_native.u32[0])

	--- Writes data to the output buffer according to a format string.
	--
	-- @tparam string format Data format descriptor string.
	-- The format string syntax is based on the format that Lua 5.3's string.unpack accepts, but does not implement all
	-- features and uses fixed instead of native data sizes.
	-- See <a href='http://www.lua.org/manual/5.3/manual.html#6.4.2'>the Lua manual</a> for details.
	--
	-- Supported format specifiers:
	--
	-- * Byte order:
	--     * `<` (little endian)
	--     * `>` (big endian)
	--     * `=` (host endian, default)
	--
	--     Byte order can be switched any number of times in a format string.
	-- * Integer types:
	--     * `b` / `B` (signed/unsigned 8 bits)
	--     * `h` / `H` (signed/unsigned 16 bits)
	--     * `l` / `L` (signed/unsigned 32 bits)
	--     * `v` / `V` (signed/unsigned variable length 32 bits) - see `BlobReader:vs32` / `BlobReader:vu32`
	--     * `q` / `Q` (signed/unsigned 64 bits)
	-- * Floating point types:
	--     * `f` (32 bits)
	--     * `d`, `n` (64 bits)
	-- * String types:
	--     * `z` (zero terminated string)
	--     * `s` (string with preceding length information). Length is stored as a `vu32` encoded value
	-- * Raw data:
	--     * `c[length]` (up to 2 ^ 32 - 1 bytes)
	-- * Boolean:
	--     * `y` (8 bits boolean value)
	-- * Table:
	--     * `t` (table written with `BlobWriter:table`
	-- * Other:
	--     * `x` skip one byte
	-- @param ... values to write
	-- @treturn BlobWriter self
	-- @usage writer\pack('Bfy', 255, 23.0, true)
	-- @see BlobReader:unpack
	pack: (format, ...) =>
		assert(type(format) == 'string', "Invalid format specifier")

		data, index, len = {...}, 1, nil
		limit = select('#', ...)

		_writeRaw = ->
			l = tonumber(table.concat(len))
			assert(l, l or "Invalid string length specification: #{table.concat(len)}")
			assert(l < 2 ^ 32, "Maximum string length exceeded")
			@raw(data[index], l)
			index, len = index + 1, nil

		format\gsub('.', (c) ->
			if len
				if tonumber(c)
					table.insert(len, c)
				else
					assert(index <= limit, "Number of arguments to pack does not match format specifiers")
					_writeRaw!

			unless len
				writer = _packMap[c]
				assert(writer, writer or "Invalid data type specifier: #{c}")
				if c == 'c'
					len = {}
				else
					assert(index <= limit, "Number of arguments to pack does not match format specifiers")
					index += 1 if writer(@, data[index])
		)
		_writeRaw! if len -- final specifier in format was a length specifier
		@

	-----------------------------------------------------------------------------

	--- Returns the current buffer contents as a string.
	--
	-- @treturn string A string with the current buffer contents
	tostring: => ffi.string(@_data, @_length)

	--- Returns the number of bytes stored in the blob.
	--
	-- @treturn number The number of bytes stored in the blob
	length: => @_length

	--- Returns the size of the write buffer in bytes
	--
	-- @treturn number Write buffer size in bytes
	size: => @_size

	--- Returns the number of bytes required to store an unsigned 32 bit value when written by `BlobWriter:vu32`.
	--
	-- @tparam number value The unsigned 32 bit value to write
	-- @treturn number The number of bytes required by `BlobWriter:vu32` to store `value`
	vu32size: (value) =>
		return 1 if value < 2 ^ 7
		return 2 if value < 2 ^ 14
		return 3 if value < 2 ^ 21
		return 4 if value < 2 ^ 28
		5

	--- Returns the number of bytes required to store a signed 32 bit value when written by `BlobWriter:vs32`.
	--
	-- @tparam number value The signed 32 bit value to write
	-- @treturn number The number of bytes required by `BlobWriter:vs32` to store `value`
	vs32size: (value) =>
		_native.s32[0] = value
		@vu32size(_native.u32[0])

	------------------------------------------------------------------------------------------------------

	_allocate: (size) =>
		local data
		if size > 0
			data = ffi.new('uint8_t[?]', size)
			ffi.copy(data, @_data, @_length) if @_data
		@_data, @_size = data, size
		@_length = math.min(size, @_length)

	_grow: (minimum) =>
		minimum = minimum or 0
		newSize = math.max(@_size + minimum, math.floor(math.max(1, @_size * 1.5) + .5))
		@_allocate(newSize)

	_writeTable: (t, stack) =>
		stack = stack or {}
		ttype = type(t)
		assert(ttype == 'table', ttype == 'table' or string.format("Invalid type '%s' for BlobWriter:table", ttype))
		assert(not stack[t], "Cycle detected; can't serialize table")

		stack[t] = true
		for key, value in pairs(t)
			@_writeTagged(key, stack)
			@_writeTagged(value, stack)
		stack[t] = nil

		@u8(_tags.stop)

	_writeTagged: (value, stack) =>
		tag = _getTag(value)
		assert(tag, tag or string.format("Can't write values of type '%s'", type(value)))
		@u8(tag)

		_taggedWriters[tag](@, value, stack)

_native = ffi.new[[
	union {
		  int8_t s8[8];
		 uint8_t u8[8];
		 int16_t s16[4];
		uint16_t u16[4];
		 int32_t s32[2];
		uint32_t u32[2];
		   float f[2];
		 int64_t s64;
		uint64_t u64;
		  double n;
	}
]]

_byteOrder =
	le: (v1, v2) => v1, v2
	be: (v1, v2) => v2, v1

_tags =
	stop: 0
	number: 1
	string: 2
	table: 3
	[true]: 4
	[false]: 5

_taggedWriters = {
	BlobWriter.number
	BlobWriter.string
	BlobWriter._writeTable
	=> @ -- true is stored as tag, write nothing
	=> @ -- false is stored as tag, write nothing
}

with BlobWriter
	_packMap =
		b: .s8
		B: .u8
		h: .s16
		H: .u16
		l: .s32
		L: .u32
		v: .vs32
		V: .vu32
		q: .s64
		Q: .u64
		f: .f32
		d: .number
		n: .number
		c: .raw
		s: .string
		z: .cString
		t: .table
		y: .bool
		['<']: => nil, @setByteOrder('<')
		['>']: => nil, @setByteOrder('>')
		['=']: => nil, @setByteOrder('=')

_parseByteOrder = (endian) ->
	switch endian
		when nil, '=', 'host'
			endian = ffi.abi('le') and 'le' or 'be'
		when '<'
			endian = 'le'
		when '>'
			endian = 'be'
		else
			error("Invalid byteOrder identifier: #{endian}")
	endian

_getTag = (value) ->
	return _tags[value] if value == true or value == false
	_tags[type(value)]

BlobWriter
