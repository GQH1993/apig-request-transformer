local path_params_mgr = require "kong.plugins.apig-request-transformer.path_params"

local _M = {}
--define
local CONTENT_TYPE = "Content-Type"
local HOST = "host"

local JSON = "json"
local FORM = "form"
local MULTIPART = "multipart"
local HEAD = "head"
local QUERY = "query"
local PATH = "path"

local ngx = ngx
local kong = kong
local next = next
local type = type
local find = string.find
local upper = string.upper
local lower = string.lower
local gsub = string.gsub


local function get_content_type(content_type)
    if content_type == nil then
        return nil
    end

    content_type = lower(content_type)

    if find(content_type, "application/json", nil, true) then
        return JSON
    end
    if find(content_type, "application/x-www-form-urlencoded", nil, true) then
        return FORM
    end
    if find(content_type, "multipart/form-data", nil, true) then
        return MULTIPART
    end

    return nil
end

local function iter(config_array)
    if type(config_array) ~= "table" then
        return
    end
    local i = 0
    return function(config_array)
        i = i + 1
        local current_pair = config_array[i]
        if current_pair == nil then
            return nil
        end
        local pos1, key1,
            pos2, key2 = current_pair:match("^([^:]+):(.+);([^:]+):(.+)$")
        return pos1, key1, pos2, key2
    end, config_array
end


--[[******************************************************************
FunctionName:	change_head_value
Purpose:		修改请求中head参数值
Parameter:
        1 opt       [int]                 处理类型 0:提取参数值 1：设置参数
        2 headers   [table]               请求头参数表
        3 key       [string]              参数的key
        4 value     [string, number, nil] 待设置的参数值

Return:
        opt为0，返回headers表和提取的参数值
        opt为1，返回headers表

Remark:     value为可选参数。opt == 1时传入
********************************************************************--]]
local function change_head_value(opt, headers, key, value)
    local val
    --local clear_header = kong.service.request.clear_header
    if opt == 0 then
      val = headers[key]
      headers[key] = nil
      --clear_header(key)

      return headers, val
    elseif opt == 1 then
      local temp_value = headers[key]
      if temp_value == nil then
        headers[key] = value --暂不考虑header里面重名key情况
      end

      return headers
    end
end

--[[******************************************************************
FunctionName:	change_query_value
Purpose:		修改请求中query参数值
Parameter:
        1 opt       [int]                 处理类型 0:提取参数值 1：设置参数
        2 querys    [table]               query参数表
        3 key       [string]              参数的key
        4 value     [string, number, nil] 待设置的参数值

Return:
        opt为0，返回querys表和提取的参数值
        opt为1，返回querys表

Remark:     value为可选参数。opt == 1时传入
********************************************************************--]]
local function change_query_value(opt, querys, key, value)
    local val
    if opt == 0 then
      val = querys[key]
      querys[key] = nil

      return querys, val
    elseif opt == 1 then
      local temp_value = querys[key]
      if temp_value == nil then
        querys[key] = value
      end

      return querys
    end
end


local function transform_param(ori_table, trans_table, conf)
    local headers = ori_table.headers
    local querys = ori_table.querys
    local path_params = path_params_mgr.parse_params(conf.requestPath, ori_table.path, conf.pathParams)

    local backend_path = conf.backendPath   --backend path
    local backend_content_type = get_content_type(conf.backendContentType) --转换后的Content-Type
    if backend_content_type ~= nil then
        headers = change_head_value(1, headers, CONTENT_TYPE, conf.backendContentType)
    end

    headers = change_head_value(1, headers, HOST, nil)

    local replace  = 0 < #conf.replace
    local add = 0 < #conf.add
    if not replace and not add then
        return trans_table
    end

    local query_changed = false
    local path_changed = false

    --常量参数及默认值
    for i = 1, #conf.add do
      local pos, key, value = conf.add[i]:match("^([^:]+):([^:]+):(.+)$")
      if pos == HEAD then
          headers = change_head_value(1, headers, key, value)
      elseif pos == QUERY then
          querys = change_query_value(1, querys, key, value)
          query_changed = true
      end
    end

    headers.host = nil

    --参数映射
    for req_param_pos, req_param, backend_param_pos, backend_param in iter(conf.replace) do
        if req_param_pos and req_param and backend_param_pos and backend_param then
            while true do
                local value
                --提取参数值
                local pos1 = lower(req_param_pos)
                if pos1 == QUERY then
                    querys, value = change_query_value(0, querys, req_param)
                    query_changed = true
                elseif pos1 == HEAD then
                    headers, value = change_head_value(0, headers, req_param)
                elseif pos1 == PATH then
                    if type(path_params) == "table" and next(path_params) then
                        value = path_params[req_param]
                    end
                end

                if value == nil then break end --跳出while true

                --映射参数值
                local pos2 = lower(backend_param_pos)
                if pos2 == HEAD then
                    headers[backend_param] = value
                elseif pos2 == QUERY then
                    querys[backend_param] = value
                    query_changed = true
                elseif pos2 == PATH then
                    backend_path = gsub(backend_path, '{'.. backend_param .. '}', value)
                    path_changed = true
                end

                break --跳出while true
            end
        end
    end

    trans_table.headers = headers
    if query_changed then
        trans_table.querys = querys
    end
    if path_changed then
        trans_table.path = backend_path
    end

    return trans_table
end

function _M.execute(ori_table, conf)
    local trans_table = {}
    --trans method
    if conf.httpMethod then
        local method = upper(conf.httpMethod)
        if method ~= ori_table.method then
            trans_table.method = method
        end
    end

    trans_table = transform_param(ori_table, trans_table, conf)

    return trans_table
end

return _M
