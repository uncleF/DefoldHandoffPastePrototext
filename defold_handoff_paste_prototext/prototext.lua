local Prototext = {}

local DEFAULT_FIELD_ORDER = {
  "script",
  "background_color",
  "fonts",
  "textures",
  "materials",
  "layers",
  "layouts",
  "nodes"
}

local function tokenize(s)
  local tokens = {}
  local n = #s
  local i = 1

  local function push(kind, value)
    tokens[#tokens + 1] = { kind = kind, value = value }
  end

  local function is_space(c)
    return c == " " or c == "\t" or c == "\n" or c == "\r"
  end

  local function is_ident_start(c)
    local b = string.byte(c)
    return (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or c == "_"
  end

  local function is_ident_char(c)
    local b = string.byte(c)
    return (b >= 65 and b <= 90)
        or (b >= 97 and b <= 122)
        or (b >= 48 and b <= 57)
        or c == "_" or c == "."
        or c == "-"
  end

  local function is_digit(c)
    local b = string.byte(c)
    return b >= 48 and b <= 57
  end

  local function skip_whitespace_and_comments()
    while i <= n do
      local c = s:sub(i, i)
      if is_space(c) then
        i = i + 1
      elseif c == "#" then
        i = i + 1
        while i <= n and s:sub(i, i) ~= "\n" do i = i + 1 end
      elseif c == "/" and s:sub(i, i + 1) == "//" then
        i = i + 2
        while i <= n and s:sub(i, i) ~= "\n" do i = i + 1 end
      else
        break
      end
    end
  end

  local function read_string()
    i = i + 1
    local out = {}
    while i <= n do
      local c = s:sub(i, i)
      if c == '"' then
        i = i + 1
        return table.concat(out)
      elseif c == "\\" then
        local nxt = s:sub(i + 1, i + 1)
        if nxt == "n" then
          out[#out + 1] = "\n"; i = i + 2
        elseif nxt == "r" then
          out[#out + 1] = "\r"; i = i + 2
        elseif nxt == "t" then
          out[#out + 1] = "\t"; i = i + 2
        elseif nxt == "\\" then
          out[#out + 1] = "\\"; i = i + 2
        elseif nxt == '"' then
          out[#out + 1] = '"'; i = i + 2
        else
          if nxt ~= "" then
            out[#out + 1] = nxt
            i = i + 2
          else
            i = i + 1
          end
        end
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
    return table.concat(out)
  end

  local function read_number_or_ident_minus()
    local start = i
    local c = s:sub(i, i)

    if c == "-" or c == "+" then
      i = i + 1
      c = s:sub(i, i)
    end

    local saw_digit = false
    while i <= n and is_digit(s:sub(i, i)) do
      saw_digit = true
      i = i + 1
    end

    if i <= n and s:sub(i, i) == "." then
      i = i + 1
      while i <= n and is_digit(s:sub(i, i)) do
        saw_digit = true
        i = i + 1
      end
    end

    if i <= n then
      local e = s:sub(i, i)
      if e == "e" or e == "E" then
        local j = i + 1
        local sign = s:sub(j, j)
        if sign == "-" or sign == "+" then j = j + 1 end
        local any = false
        while j <= n and is_digit(s:sub(j, j)) do
          any = true
          j = j + 1
        end
        if any then i = j end
      end
    end

    local lex = s:sub(start, i - 1)
    if saw_digit then
      push("number", lex)
    else
      push("ident", lex)
    end
  end

  local function read_ident()
    local start = i
    i = i + 1
    while i <= n and is_ident_char(s:sub(i, i)) do
      i = i + 1
    end
    push("ident", s:sub(start, i - 1))
  end

  while true do
    skip_whitespace_and_comments()
    if i > n then break end

    local c = s:sub(i, i)
    if c == "{" or c == "}" or c == ":" then
      push("symbol", c)
      i = i + 1
    elseif c == '"' then
      local str = read_string()
      push("string", str)
    elseif c == "-" or c == "+" then
      read_number_or_ident_minus()
    elseif is_digit(c) then
      read_number_or_ident_minus()
    elseif is_ident_start(c) then
      read_ident()
    else
      i = i + 1
    end
  end

  push("eof", "")
  return tokens
end

local function parse_tokens(tokens)
  local pos = 1

  local function peek()
    return tokens[pos]
  end

  local function next_token()
    local t = tokens[pos]
    pos = pos + 1
    return t
  end

  local function expect(kind, value)
    local t = next_token()
    if not t or t.kind ~= kind or (value and t.value ~= value) then
      return nil, t
    end
    return t
  end

  local function parse_scalar()
    local t = next_token()
    if t.kind == "string" then
      return { kind = "scalar", type = "string", value = t.value, raw = t.value }
    elseif t.kind == "number" then
      return { kind = "scalar", type = "number", value = tonumber(t.value) or t.value, raw = t.value }
    elseif t.kind == "ident" then
      if t.value == "true" or t.value == "false" then
        return { kind = "scalar", type = "bool", value = (t.value == "true"), raw = t.value }
      end
      return { kind = "scalar", type = "ident", value = t.value, raw = t.value }
    end
    return { kind = "scalar", type = "ident", value = "", raw = "" }
  end

  local function parse_message(stop_on_rbrace)
    local msg = { kind = "msg", fields = {} }

    while true do
      local t = peek()
      if not t then break end
      if t.kind == "eof" then break end
      if stop_on_rbrace and t.kind == "symbol" and t.value == "}" then
        break
      end

      if t.kind ~= "ident" then
        next_token()
      else
        local key = next_token().value
        local t2 = peek()
        if not t2 then break end

        if t2.kind == "symbol" and t2.value == ":" then
          next_token()
          local item = parse_scalar()
          local arr = msg.fields[key]
          if not arr then
            arr = {}; msg.fields[key] = arr
          end
          arr[#arr + 1] = item
        elseif t2.kind == "symbol" and t2.value == "{" then
          next_token()
          local child = parse_message(true)
          expect("symbol", "}")
          local arr = msg.fields[key]
          if not arr then
            arr = {}; msg.fields[key] = arr
          end
          arr[#arr + 1] = child
        else
          next_token()
        end
      end
    end

    return msg
  end

  return parse_message(false)
end

function Prototext.parse(text)
  local toks = tokenize(text or "")
  return parse_tokens(toks)
end

local function escape_string(s)
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  s = s:gsub("\t", "\\t")
  return s
end

local function scalar_to_text(scalar)
  if scalar.type == "string" then
    return '"' .. escape_string(tostring(scalar.value or "")) .. '"'
  elseif scalar.type == "bool" then
    return (scalar.value and "true" or "false")
  elseif scalar.type == "number" then
    if type(scalar.raw) == "string" and scalar.raw ~= "" then return scalar.raw end
    return tostring(scalar.value)
  else
    return tostring(scalar.value or "")
  end
end

local function build_order_map(order)
  local map = {}
  for i, k in ipairs(order or {}) do map[k] = i end
  return map
end

local function sorted_keys(fields, order_map)
  local keys = {}
  for k, _ in pairs(fields) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    local ia = order_map[a] or 1e9
    local ib = order_map[b] or 1e9
    if ia ~= ib then return ia < ib end
    return a < b
  end)
  return keys
end

local function serialize_message(msg, indent, order_map)
  indent = indent or ""
  local out = {}

  local keys = sorted_keys(msg.fields, order_map)
  for _, key in ipairs(keys) do
    local arr = msg.fields[key]
    for _, item in ipairs(arr) do
      if item.kind == "scalar" then
        out[#out + 1] = indent .. key .. ": " .. scalar_to_text(item) .. "\n"
      else
        out[#out + 1] = indent .. key .. " {\n"
        out[#out + 1] = serialize_message(item, indent .. "  ", order_map)
        out[#out + 1] = indent .. "}\n"
      end
    end
  end

  return table.concat(out)
end

local function get_scalar_item(msg, key)
  local arr = msg.fields[key]
  if not arr then return nil end
  local item = arr[1]
  if item and item.kind == "scalar" then return item end
  return nil
end

local function get_string_scalar(msg, key)
  local it = get_scalar_item(msg, key)
  if not it then return nil end
  return it.value
end

local function set_string_scalar(msg, key, value)
  msg.fields[key] = { { kind = "scalar", type = "string", value = value, raw = value } }
end

local function build_used_id_map(dst_nodes)
  local used = {}
  for _, node in ipairs(dst_nodes) do
    if node.kind == "msg" then
      local id = get_string_scalar(node, "id")
      if id and id ~= "" then
        used[id] = true
      end
    end
  end
  return used
end

local function resolve_unique_id(base, used)
  if not used[base] then return base end
  local idx = 1
  while true do
    local candidate = base .. "_" .. idx
    if not used[candidate] then
      return candidate
    end
    idx = idx + 1
  end
end

function Prototext.serialize(msg, field_order)
  local order_map = build_order_map(field_order or DEFAULT_FIELD_ORDER)
  local s = serialize_message(msg, "", order_map)
  if s:sub(-1) ~= "\n" then s = s .. "\n" end
  return s
end

function Prototext.get_first_scalar(msg, key)
  local arr = msg.fields[key]
  if not arr then return nil end
  local item = arr[1]
  if item and item.kind == "scalar" then return item.value, item end
  return nil
end

function Prototext.set_scalar(msg, key, scalar_type, value, raw)
  local item = { kind = "scalar", type = scalar_type, value = value, raw = raw }
  msg.fields[key] = { item }
end

function Prototext.ensure_scalar(msg, key, scalar_type, value)
  if not msg.fields[key] then
    Prototext.set_scalar(msg, key, scalar_type, value)
  end
end

function Prototext.append_msg(msg, key, child_msg)
  local arr = msg.fields[key]
  if not arr then
    arr = {}; msg.fields[key] = arr
  end
  arr[#arr + 1] = child_msg
end

function Prototext.items(msg, key)
  return msg.fields[key] or {}
end

local function build_seen_by_name(items)
  local seen = {}
  for _, it in ipairs(items) do
    if it.kind == "msg" then
      local name = Prototext.get_first_scalar(it, "name")
      if type(name) == "string" and name ~= "" then
        seen[name] = true
      end
    end
  end
  return seen
end

function Prototext.merge_unique_by_name(dst_msg, src_msg, key)
  local dst_items = Prototext.items(dst_msg, key)
  local src_items = Prototext.items(src_msg, key)
  if #src_items == 0 then return 0 end
  if #dst_items == 0 then
    dst_msg.fields[key] = src_items
    return #src_items
  end

  local seen = build_seen_by_name(dst_items)
  local added = 0
  for _, it in ipairs(src_items) do
    if it.kind == "msg" then
      local name = Prototext.get_first_scalar(it, "name")
      if type(name) == "string" and name ~= "" and not seen[name] then
        seen[name] = true
        dst_items[#dst_items + 1] = it
        added = added + 1
      end
    end
  end
  return added
end

function Prototext.add_nodes(dst_msg, clipboard_msg, parent_id)
  local incoming = Prototext.items(clipboard_msg, "nodes")
  if #incoming == 0 then return 0 end

  local dst_nodes = Prototext.items(dst_msg, "nodes")
  if not dst_msg.fields["nodes"] then
    dst_msg.fields["nodes"] = dst_nodes
  end

  local used = build_used_id_map(dst_nodes)

  local renamed = {}

  for _, node in ipairs(incoming) do
    if node.kind == "msg" then
      if parent_id and not node.fields["parent"] then
        set_string_scalar(node, "parent", parent_id)
      end

      local id_item = get_scalar_item(node, "id")
      if id_item and id_item.value then
        local old_id = tostring(id_item.value)
        if old_id ~= "" then
          local new_id = resolve_unique_id(old_id, used)
          if new_id ~= old_id then
            renamed[old_id] = new_id
            id_item.value = new_id
            id_item.raw = new_id
          end
          used[new_id] = true
        end
      end
    end
  end

  if next(renamed) ~= nil then
    for _, node in ipairs(incoming) do
      if node.kind == "msg" then
        local p_item = get_scalar_item(node, "parent")
        if p_item and p_item.value then
          local p = tostring(p_item.value)
          local mapped = renamed[p]
          if mapped then
            p_item.value = mapped
            p_item.raw = mapped
          end
        end
      end
    end
  end

  for _, node in ipairs(incoming) do
    if node.kind == "msg" then
      dst_nodes[#dst_nodes + 1] = node
    end
  end

  return #incoming
end

return Prototext
