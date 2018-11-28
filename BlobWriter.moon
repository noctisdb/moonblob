-- @class BlobWriter
ffi = require('ffi')
band, bnot, shr, shl = bit.band, bit.bnot, bit.rshift, bit.lshift

local _byteOrder, _parseByteOrder
local _tags, _getTag, _taggedReaders, _taggedWriters, _packMap, _unpackMap, _arrayTypeMap

--- Writes binary data to memory.
class BlobWriter
	--- Creates a new BlobWriter instance.
	--
	-- @tparam[opt] number|string sizeOrByteOrder Size or byte order
	--
	-- **Byte order**: Use `le` or `<` for little endian; `be` or `>` for big endian; `host`, `=` or `nil` to use the
	-- host's native byteOrder (default)
	--
	-- @tparam[opt] number size The initial size of the blob in bytes. Default is 1024. Will grow automatically when
	-- required.
	-- @treturn BlobWriter A new BlobWriter instance.
	-- @usage writer = BlobWriter!
	-- @usage writer = BlobWriter('<', 1000)
	-- @see clear
	new: (sizeOrByteOrder, size) =>
		@_native = ffi.new[[
			union {
				  int8_t s8[8];
				 uint8_t u8[8];
				 int16_t s16[4];
				uint16_t u16[4];
				 int32_t s32[2];
				uint32_t u32[2];
				   float f32[2];
				 int64_t s64;
				uint64_t u64;
				  double f64;
			}
		]]

		byteOrder = type(sizeOrByteOrder) == 'string' and sizeOrByteOrder or nil
		size = type(sizeOrByteOrder) == 'number' and sizeOrByteOrder or size
		@_length, @_size = 0, 0
		@setByteOrder(byteOrder)
		@_allocate(size or 1024)

	--- Writes a value to the output buffer. Determines the type of the value automatically.
	--
	-- Supported value types are `number`, `string`, `boolean` and `table`.
	-- @param value the value to write
	-- @treturn BlobWriter self
	write: (value) => @_writeTagged(value)

	--- Writes a Lua number to the output buffer.
	--
	-- @tparam number value The number to write
	-- @treturn BlobWriter self
	number: (value) =>
		@_native.f64 = value
		@u32(@_native.u32[0])\u32(@_native.u32[1])

	--- Writes a boolean value to the output buffer.
	--
	-- The value is written as an unsigned 8 bit value (`true = 1`, `false = 0`)
	-- @tparam bool value The boolean value to write
	--
	-- @treturn BlobWriter self
	bool: (value) => @u8(value and 1 or 0)

	--- Writes a string to the output buffer.
	--
	-- Stores the length of the string as a `vu32` field before the actual string data.
	-- @tparam string value The string to write
	-- @treturn BlobWriter self
	string: (value) =>
		length = #value
		@vu32(length)\raw(value, length)

	--- Writes an unsigned 8 bit value to the output buffer.
	--
	-- @tparam number value The value to write
	-- @treturn BlobWriter self
	u8: (value) =>
		@_grow(1) if @_length + 1 > @_size
		@_data[@_length] = value
		@_length += 1
		@

	--- Writes a signed 8 bit value to the output buffer.
	--
	-- @tparam number value The value to write
	-- @treturn BlobWriter self
	s8: (value) =>
		@_native.s8[0] = value
		@u8(@_native.u8[0])

	--- Writes an unsigned 16 bit value to the output buffer.
	--
	-- @tparam number value The value to write
	-- @treturn BlobWriter self
	u16: (value) =>
		len = @_length
		@_grow(2) if len + 2 > @_size
		@_data[len], @_data[len + 1] = @._orderBytes(band(value, 2 ^ 8 - 1), shr(value, 8))
		@_length += 2
		@

	--- Writes a signed 16 bit value to the output buffer.
	--
	-- @tparam number value The value to write
	-- @treturn BlobWriter self
	s16: (value) =>
		@_native.s16[0] = value
		@u16(@_native.u16[0])

	--- Writes an unsigned 32 bit value to the output buffer.
	--
	-- @tparam number value The value to write
	-- @treturn BlobWriter self
	u32: (value) =>
		len = @_length
		@_grow(4) if len + 4 > @_size
		w1, w2 = @._orderBytes(band(value, 2 ^ 16 - 1), shr(value, 16))
		b1, b2 = @._orderBytes(band(w1, 2 ^ 8 - 1), shr(w1, 8))
		b3, b4 = @._orderBytes(band(w2, 2 ^ 8 - 1), shr(w2, 8))
		@_data[len], @_data[len + 1], @_data[len + 2], @_data[len + 3] = b1, b2, b3, b4
		@_length += 4
		@

	--- Writes a signed 32 bit value to the output buffer.
	--
	-- @tparam number value The value to write
	-- @treturn BlobWriter self
	s32: (value) =>
		@_native.s32[0] = value
		@u32(@_native.u32[0])

	--- Writes a length-encoded unsigned 32 bit integer value.
	--
	-- The value is written in an encoded format. The length depends on the value; larger values need more space.
	--
	-- Space requirements:
	--
	--     | lower bound | upper bound | # bytes |
	--     |-------------|-------------|---------|
	--     |           0 |         127 |    1    |
	--     |         128 |       16383 |    2    |
	--     |       16384 |     2097151 |    3    |
	--     |     2097151 |   268435455 |    4    |
	--     |   268435456 |  4294967295 |    5    |
	--
	-- @{vu32size} computes the space requirement for an unsigned integer value.
	-- @tparam number value The unsigned integer value to write
	-- @treturn BlobWriter self
	-- @see BlobWriter:vu32size
	vu32: (value) =>
		error("Exceeded u32 value limits") unless value < 2 ^ 32

		for i = 7, 28, 7
			mask, shift = 2 ^ i - 1, i - 7
			return @u8(shr(band(value, mask), shift)) if value < 2 ^ i
			@u8(shr(band(value, mask), shift) + 0x80)
		@u8(shr(band(value, 0xf0000000), 28))

	--- Writes a length-encoded signed 32 bit integer.
	--
	-- The value is written in an encoded format. The length depends on the value; larger values need more space.
	--
	-- Space requirements:
	-- 	| lower bound | upper bound | # bytes |
	-- 	|-------------|-------------|---------|
	-- 	| -2147483648 |  -268435455 |    5    |
	-- 	|  -268435454 |    -2097151 |    4    |
	-- 	|   -2097150  |      -16383 |    3    |
	-- 	|     -16382  |        -127 |    2    |
	-- 	|       -126  |         126 |    1    |
	-- 	|        127  |       16382 |    2    |
	-- 	|      16383  |     2097150 |    3    |
	-- 	|    2097151  |   268435454 |    4    |
	-- 	|  268435455  |  2147483647 |    5    |
	--
	-- @{vs32size} computes the space requirement for a signed integer value.
	-- @tparam number value The signed integer value to write
	-- @treturn BlobWriter self
	-- @see BlobWriter:vu32
	-- @see BlobWriter:vs32size
	vs32: (value) =>
		error("Exceeded s32 value limits") unless value < 2 ^ 31 and value >= -2^31

		signBit, value = value < 0 and 1 or 0, math.abs(value)
		return @u8(shl(band(value, 0x3f), 1) + signBit) if value < 2 ^ 6
		@u8(shl(band(value, 0x3f), 1) + signBit + 0x80)

		for i = 13, 27, 7
			mask, shift = 2 ^ i - 1, i - 7
			return @u8(shr(band(value, mask), shift)) if value < 2 ^ i
			@u8(shr(band(value, mask), shift) + 0x80)
		@u8(shr(band(value, 0xf8000000), 27))

	--- Writes an unsigned 64 bit value to the output buffer.
	--
	-- Lua numbers are only accurate for values < 2 ^ 53. Use the LuaJIT `ULL` suffix to write large numbers.
	-- @usage writer\u64(72057594037927936ULL)
	-- @tparam number value The value to write
	-- @treturn BlobWriter self
	u64: (value) =>
		@_native.u64 = value
		a, b = @._orderBytes(@_native.u32[0], @_native.u32[1])
		@u32(a)\u32(b)

	--- Writes a signed 64 bit value to the output buffer.
	--
	-- @tparam number value The value to write
	-- @treturn BlobWriter self
	-- @see BlobWriter:u64
	s64: (value) =>
		@_native.s64 = value
		a, b = @._orderBytes(@_native.u32[0], @_native.u32[1])
		@u32(a)\u32(b)

	--- Writes a 32 bit floating point value to the output buffer.
	--
	-- @tparam number value The value to write
	-- @treturn BlobWriter self
	f32: (value) =>
		@_native.f32[0] = value
		@u32(@_native.u32[0])

	--- Writes a 64 bit floating point value to the output buffer.
	---
	-- @tparam number value The value to write
	-- @treturn BlobWriter self
	f64: (value) => @number(value)

	--- Writes raw binary data to the output buffer.
	--
	-- @tparam string|cdata value A `string` or `cdata` with the data to write
	-- @tparam[opt] number length Length of data (not required when data is a string)
	-- @treturn BlobWriter self
	raw: (value, length) =>
		length = length or #value
		makeRoom = (@_size - @_length) - length
		@_grow(math.abs(makeRoom)) if makeRoom < 0
		ffi.copy(ffi.cast('uint8_t*', @_data + @_length), value, length)
		@_length += length
		@

	--- Writes a string to the output buffer, followed by a null byte.
	--
	-- @tparam string value The string to write
	-- @treturn BlobWriter self
	cstring: (value) => @raw(value)\u8(0)

	--- Writes a table to the output buffer.
	--
	-- Supported field types are number, string, bool and table. Cyclic references throw an error.
	-- @tparam table value The table to write
	-- @treturn BlobWriter self
	table: (value) => @_writeTable(value, {})

	--- Writes a sequential table of values. All values must be of the same type.
	--
	-- @tparam string valueType Type of the values in the array
	--
	-- Valid types are `s8`, `u8`, `s16`, `u16`, `s32`, `u32`, `vs32`, `vu32`, `s64`, `u64`, `f32`, `f64`,
	-- `number`, `string`, `bool`, `cstring`, and `table`.
	--
	-- Stores the array length as a `vu32` encoded value before the actual table values.
	--
	-- @tparam table value A sequential table of values of type `valueType`
	--
	-- Maximum allowed length is `2 ^ 32 - 1` values.
	-- Behavior is undefined for table keys that are not sequential, or not starting at index 1.
	--
	-- @treturn BlobWriter self
	array: (valueType, value) =>
		writer = _arrayTypeMap[valueType]
		error("Invalid array type <#{valueType}>") unless writer
		@vu32(#value)
		writer(@, v) for v in *value
		@

	--- Writes data according to a format string.
	--
	-- @tparam string format Data format descriptor string.
	-- The format string syntax is loosely based on the format that Lua 5.3's
	-- [string.pack](http://www.lua.org/manual/5.3/manual.html#6.4.2) accepts, but does not implement all
	-- features and uses fixed instead of native data sizes.
	--
	-- Supported format specifiers:
	--
	-- * Byte order:
	--     * `<`: little endian
	--     * `>`: big endian
	--     * `=`: host endian, default
	--
	--     Byte order can be switched any number of times in a format string.
	-- * Integer types:
	--     * `b` / `B`: signed/unsigned 8 bits
	--     * `h` / `H`: signed/unsigned 16 bits
	--     * `l` / `L`: signed/unsigned 32 bits
	--     * `v` / `V`: signed/unsigned variable length 32 bits (see @{vs32} / @{vu32})
	--     * `q` / `Q`: signed/unsigned 64 bits
	-- * Boolean:
	--     * `y`: 8 bits boolean value
	-- * Floating point types:
	--     * `f`: 32 bits floating point
	--     * `d`, `n`: 64 bits floating point
	-- * String types:
	--     * `z`: zero terminated string
	--     * `s`: string with preceding length information. Length is stored as a `vu32` encoded value
	-- * Raw data:
	--     * `c[length]`: Raw binary data
	-- * Table:
	--     * `t`: table as written by @{table}
	--
	-- @param ... values to write
	-- @treturn BlobWriter self
	-- @usage writer\pack('Bfy', 255, 23.0, true)
	-- @see BlobReader:unpack
	pack: (format, ...) =>
		data, index, len = {...}, 1, nil
		limit = select('#', ...)

		_writeRaw = ->
			l = tonumber(table.concat(len))
			error("Invalid string length specification: #{table.concat(len)}") unless l
			error("Maximum string length exceeded") unless l < 2 ^ 32
			@raw(data[index], l)
			index, len = index + 1, nil

		format\gsub('.', (c) ->
			if len
				if tonumber(c)
					table.insert(len, c)
				else
					error("Number of arguments to pack does not match format specifiers") unless index <= limit
					_writeRaw!

			unless len
				writer = _packMap[c]
				error("Invalid data type specifier: #{c}") unless writer
				if c == 'c'
					len = {}
				else
					error("Number of arguments to pack does not match format specifiers") unless index <= limit
					index += 1 if writer(@, data[index])
		)
		_writeRaw! if len -- final specifier in format was a length specifier
		@

	-----------------------------------------------------------------------------

	--- Clears the blob and discards all buffered data.
	--
	-- @tparam[opt] number size Set the writer buffer size to this value. If `nil`, the currently allocated buffer
	-- is reused.
	-- @treturn BlovWriter self
	clear: (size) =>
		@_length = 0
		if size
			@_data = nil
			@_allocate(size)
		@

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

	--- Returns the number of bytes required to store an unsigned 32 bit value when written by @{vu32}.
	--
	-- @tparam number value The unsigned 32 bit value to write
	-- @treturn number The number of bytes required by @{vu32} to store `value`
	vu32size: (value) =>
		error("Exceeded u32 value limits") unless value < 2 ^ 32
		return 1 if value < 2 ^ 7
		return 2 if value < 2 ^ 14
		return 3 if value < 2 ^ 21
		return 4 if value < 2 ^ 28
		5

	--- Returns the number of bytes required to store a signed 32 bit value when written by @{vs32}.
	--
	-- @tparam number value The signed 32 bit value to write
	-- @treturn number The number of bytes required by @{vs32} to store `value`
	vs32size: (value) =>
		error("Exceeded s32 value limits") unless value < 2 ^ 31 and value >= -2 ^ 31
		value = math.abs(value) + 1
		return 1 if value < 2 ^ 7
		return 2 if value < 2 ^ 14
		return 3 if value < 2 ^ 21
		return 4 if value < 2 ^ 28
		5

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

	------------------------------------------------------------------------------------------------------

	_allocate: (size) =>
		local data
		if size > 0
			data = ffi.new('uint8_t[?]', size)
			ffi.copy(data, @_data, @_length) if @_data
		@_data, @_size = data, size
		@_length = math.min(size, @_length)

	_grow: (minimum = 0) =>
		newSize = math.max(@_size + minimum, math.floor(math.max(1, @_size * 1.5) + .5))
		@_allocate(newSize)

	_writeTable: (t, stack) =>
		stack, ttype = stack or {}, type(t)
		error("Cycle detected; can't serialize table") if stack[t]

		stack[t] = true
		for key, value in pairs(t)
			@_writeTagged(key, stack)
			@_writeTagged(value, stack)
		stack[t] = nil

		@u8(_tags.stop)

	_writeTagged: (value, stack) =>
		tag = _getTag(value)
		error("Can't write values of type '#{type(value)}'") unless tag
		@u8(tag)

		_taggedWriters[tag](@, value, stack)

_byteOrder =
	le: (v1, v2) -> v1, v2
	be: (v1, v2) -> v2, v1

_tags =
	stop: 0
	number: 1
	string: 2
	table: 3
	[true]: 4
	[false]: 5
	zero: 6
	vs32: 7
	vu32: 8
	vs64: 9
	vu64: 10

with BlobWriter
	_taggedWriters = {
		.number
		.string
		._writeTable
		=> @ -- true
		=> @ -- false
		=> @ -- 0
		.vs32
		.vu32
		(val) =>
			@_native.s64 = val
			@vs32(@_native.s32[0])\vs32(@_native.s32[1])
		(val) =>
			@_native.u64 = val
			@vu32(@_native.u32[0])\vs32(@_native.u32[1])
	}

	_arrayTypeMap =
		s8:      .s8
		u8:      .u8
		s16:     .s16
		u16:     .u16
		s32:     .s32
		u32:     .u32
		s64:     .s64
		u64:     .u64
		vs32:    .vs32
		vu32:    .vu32
		f32:     .f32
		f64:     .f64
		number:  .number
		string:  .string
		cstring: .cstring
		bool:    .bool
		table:   .table

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
		z: .cstring
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
	t = type(value)
	switch t
		when 'boolean'
			return _tags[value]
		when 'number'
			return _tags.zero if value == 0
			return _tags.number if math.floor(value) ~= value
			if value >= 0
				return _tags.vu32 if value < 2 ^ 32
				return _tags.vu64
			return _tags.vs32 if value >= -2 ^ 31
			return _tags.vs64
	_tags[t]

BlobWriter
