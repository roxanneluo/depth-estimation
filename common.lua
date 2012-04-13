require 'torch'
require 'xlua'
require 'sys'

function round(x)
   return math.floor(x+0.5)
end

function modProgress(i, max, mod)
   if math.mod(i, mod) == 0 then
      xlua.progress(i, max)
   end
end

function randInt(a, b) --a included, b excluded
   return math.floor(torch.uniform(a, b))
end

function randomPermutation(n)
   local ret = torch.Tensor(n)
   for i = 1,n do
      local rnd = randInt(1, i+1)
      ret[i] = ret[rnd]
      ret[rnd] = i
   end
   return ret
end

-- Get the median of a table.
function median(t)
  local temp={}

  -- deep copy table so that when we sort it, the original is unchanged
  -- also weed out any non numbers
  for k,v in pairs(t) do
    if type(v) == 'number' then
      table.insert( temp, v )
    end
 end

  if (#temp == 0) then
     print("error: median : empty table")
  end

  table.sort( temp )

  -- If we have an even number of table elements or odd.
  if math.fmod(#temp,2) == 0 then
    -- return mean value of middle two elements
    return ( temp[#temp/2] + temp[(#temp/2)+1] ) / 2
  else
    -- return middle elements
    return temp[math.ceil(#temp/2)]
  end
end

function split(str, char)
   local nb, ne
   local e = 0
   ret = {}
   while true do
      nb, ne = str:find(char, e+1)
      if nb == nil then
	 table.insert(ret, str:sub(e+1))
	 return ret
      end
      table.insert(ret, str:sub(e+1, nb-1))
      e = ne
   end
end

function strip(str, chars)
   local function nochar(a)
      for i = 1,#chars do
	 if a == chars[i] then
	    return false
	 end
      end
      return true
   end
   local i = 1
   while i <= str:len() do
      if nochar(str:sub(i,i)) then
	 break
      end
      i = i+1
   end
   local str2 = str:sub(i)
   i = str2:len()
   while i >= 1 do
      if nochar(str2:sub(i,i)) then
	 break
      end
      i = i-1
   end
   return str2:sub(1,i)
end

function ls2(dir, ext_filter)
   local ls = split(sys.execute('ls ' .. dir), '\n')
   local ret = {}
   for i = 1,#ls do
      local a = strip(ls[i],' ')
      if a ~= '' then
	 if ext_filter then
	    if a:sub(-ext_filter:len()) == ext_filter then
	       table.insert(ret, a)
	    end
	 else
	    table.insert(ret, a)
	 end
      end
   end
   return ret
end