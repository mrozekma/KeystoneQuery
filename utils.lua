-- http://lua-users.org/wiki/StringRecipes
function string.starts(String,Start)
   return string.sub(String,1,string.len(Start))==Start
end
function string.ends(String,End)
   return End=='' or string.sub(String,-string.len(End))==End
end

-- https://www.lua.org/pil/19.3.html
function table.pairsByKeys (t, f)
	local a = {}
	for n in pairs(t) do table.insert(a, n) end
	table.sort(a, f)
	local i = 0
	local iter = function ()
		i = i + 1
		if a[i] == nil then return nil
		else return a[i], t[a[i]]
		end
	end
	return iter
end

function table.flip(table)
	local rtn = {}
	for k, v in ipairs(table) do
		rtn[v] = k
	end
	return rtn
end

function nameWithRealm(player)
	if strfind(player, '-') then
		return player
	else
		return format("%s-%s", player, GetRealmName())
	end
end

function printf(...)
	return print(format(...))
end
