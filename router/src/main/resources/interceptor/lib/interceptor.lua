--[[
Copyright (c) 2021, WSO2 Inc. (http://www.wso2.org) All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

]]

--- interceptor module
-- @module interceptor
local interceptor = {}

local json = require 'home.wso2.interceptor.lib.json'
-- json library: https://github.com/rxi/json.lua
local base64 = require 'home.wso2.interceptor.lib.base64'
-- base64 library: https://github.com/iskolbin/lbase64

-- keys of includes table
local INCLUDES = {
    INV_CONTEXT = "invocationContext",
    REQ_HEADERS = "requestHeaders",
    REQ_BODY = "requestBody",
    REQ_TRAILERS = "requestTrailers",
    RESP_HEADERS = "responseHeaders",
    RESP_BODY = "responseBody",
    RESP_TRAILERS = "responseTrailers"
}

-- keys of the payload to the interceptor service
local REQUEST = {
    REQ_HEADERS = "requestHeaders",
    REQ_BODY = "requestBody",
    REQ_TRAILERS = "requestTrailers",
    RESP_HEADERS = "responseHeaders",
    RESP_BODY = "responseBody",
    RESP_TRAILERS = "responseTrailers",
    INTCPT_CONTEXT = "interceptorContext",
    INV_CONTEXT = "invocationContext"
}

-- keys of the payload to the invocation context
local INV_CONTEXT = {
    PROTOCOL = "protocol",
    SCHEME = "scheme",
    PATH = "path",
    SOURCE = "source",
    DESTINATION = "destination",
    ENFORCER_DENIED = "enforcerDenied"
}

-- keys of the payload from the interceptor service
local RESPOSE = {
    DIRECT_RESPOND = "directRespond",
    HEADERS_TO_ADD = "headersToAdd",
    HEADERS_TO_REPLACE = "headersToReplace",
    HEADERS_TO_REMOVE = "headersToRemove",
    TRAILERS_TO_ADD = "trailersToAdd",
    TRAILERS_TO_REPLACE = "trailersToReplace",
    TRAILERS_TO_REMOVE = "trailersToRemove",
    INTCPT_CONTEXT = "interceptorContext",
}

-- table of information shared between request and response flow
local SHARED = {
    REQUEST_ID = "requestId"
}

-- envoy headers
local STATUS = ":status"

local function modify_headers(handle, interceptor_response_body)
    -- priority: headersToAdd, headersToReplace, headersToRemove
    if interceptor_response_body[RESPOSE.HEADERS_TO_REMOVE] then
        for _, key in ipairs(interceptor_response_body[RESPOSE.HEADERS_TO_REMOVE]) do
            handle:headers():remove(key)
        end
    end
    if interceptor_response_body[RESPOSE.HEADERS_TO_REPLACE] then
        for key, val in pairs(interceptor_response_body[RESPOSE.HEADERS_TO_REPLACE]) do
            handle:headers():replace(key, val)
        end
    end
    if interceptor_response_body[RESPOSE.HEADERS_TO_ADD] then
        for key, val in pairs(interceptor_response_body[RESPOSE.HEADERS_TO_ADD]) do
            handle:headers():add(key, val)
        end
    end
end

local function modify_trailers(handle, interceptor_response_body)
    -- priority: trailersToAdd, trailersToReplace, trailersToRemove
    if interceptor_response_body[RESPOSE.TRAILERS_TO_ADD] then
        for _, key in ipairs(interceptor_response_body[RESPOSE.TRAILERS_TO_ADD]) do
            handle:trailers():remove(key)
        end
    end
    if interceptor_response_body[RESPOSE.TRAILERS_TO_REPLACE] then
        for key, val in pairs(interceptor_response_body[RESPOSE.TRAILERS_TO_REPLACE]) do
            handle:trailers():replace(key, val)
        end
    end
    if interceptor_response_body[RESPOSE.TRAILERS_TO_REMOVE] then
        for key, val in pairs(interceptor_response_body[RESPOSE.TRAILERS_TO_REMOVE]) do
            handle:trailers():add(key, val)
        end
    end
end

local function modify_body(handle, interceptor_response_body, request_id)
    -- if "body" is not defined or null (i.e. {} or {"body": null}) do not update the body
    if interceptor_response_body.body then
        handle:logDebug("Updating body for the request_id: " .. request_id)
        local content_length = handle:body():setBytes(base64.decode(interceptor_response_body.body))
        handle:headers():replace("content-length", content_length)
    end
end

local function direct_respond(handle, headers, body, shared_info)
    shared_info[RESPOSE.DIRECT_RESPOND] = true
    handle:streamInfo():dynamicMetadata():set("envoy.filters.http.lua", "shared.info", shared_info)
    handle:respond(
        headers,
        body
    )
end

--- check for errors from interceptor response and handle error with responding to client
---@param handle table
---@param headers table
---@param body_str string
---@param request_id string
---@param is_request_flow boolean
---@return boolean - returns true if the rest of the flow should be terminated (do not continnue)
local function check_interceptor_call_errors(handle, headers, body_str, shared_info, request_id, is_request_flow)
    -- TODO: (renuka) check behaviour 100 continue and handle it
    if headers[STATUS] == "200" then -- success, continue flow
        return false
    end
    if headers[STATUS] == "204" then -- handle empty body, terminate flow
        return true
    end
    
    handle:logErr('Invalid interceptor service response, HTTP status_code: "' .. headers[STATUS] ..
        '", message: "' .. body_str .. '"' .. ', request_id: "' .. request_id .. '"')
    local resp_headers = {[STATUS] = "500"}
    -- TODO: (renuka) check the error code - get new error code
    local resp_body = '{"error_message": "Internal Server Error", "error_description": "Internal Server Error", "code": "00000"}'
    
    --#region request flow
    if is_request_flow then
        direct_respond(
            handle,
            resp_headers,
            resp_body,
            shared_info
        )
        return true
    end
    --#endregion

    --#region response flow
    local backend_headers = handle:headers()
    for key, _ in pairs(backend_headers) do -- remmove all headers from backend
        backend_headers:remove(key)
    end
    modify_body(handle, {body = resp_body}, request_id)
    return true
    --#endregion
end

-- TODO: (renuka) check what to log as trace and debug

--- send an HTTP request to the interceptor
-- @param handle request/response handler object
-- @param interceptor_request_body a table of request body for the interceptor service
-- @param intercept_service a table of connection details for the interceptor service
-- @return a table of respose headers
-- @return a string of response body
local function send_http_call(handle, interceptor_request_body, intercept_service)
    local headers, interceptor_response_body_str = handle:httpCall(
        intercept_service["cluster_name"],
        {
            [":method"] = "POST",
            [":path"] = intercept_service["resource_path"],
            [":authority"] = "cc-interceptor",
            ["content-type"] = "application/json",
            ["accept"] = "application/json",
        },
        json.encode(interceptor_request_body),
        intercept_service["timeout"],
        false -- async false, wait for response from interceptor service
    )

    return headers, interceptor_response_body_str
end

local function update_request_body(includes, interceptor_request_body, body_key, body_value)
    if includes[body_key] then
        interceptor_request_body[body_key] = body_value
    end
end

-- include request information in the request body to interceptor service
local function include_request_info(req_includes, interceptor_request_body, request_headers_table, request_body_base64, request_trailers_table)
    update_request_body(req_includes, interceptor_request_body, REQUEST.REQ_HEADERS, request_headers_table)
    update_request_body(req_includes, interceptor_request_body, REQUEST.REQ_BODY, request_body_base64)
    update_request_body(req_includes, interceptor_request_body, REQUEST.REQ_TRAILERS, request_trailers_table)
end

local function include_invocation_context(handle, req_includes, resp_includes, inv_context, interceptor_request_body, shared_info, request_headers)
    if req_includes[INCLUDES.INV_CONTEXT] or resp_includes[INCLUDES.INV_CONTEXT] then
        local client_ip = request_headers:get("x-forwarded-for")
        if client_ip == nil or client_ip == "" then
            client_ip = handle:streamInfo():downstreamDirectRemoteAddress()
        end

        --#region append runtime invocation details
        inv_context[INV_CONTEXT.PROTOCOL] = handle:streamInfo():protocol()
        inv_context[INV_CONTEXT.SCHEME] = request_headers:get(":scheme")
        inv_context[INV_CONTEXT.PATH] = request_headers:get(":path")
        inv_context[INV_CONTEXT.SOURCE] = client_ip
        inv_context[INV_CONTEXT.DESTINATION] = handle:streamInfo():downstreamLocalAddress() -- TODO: check this viraj, amali
        inv_context[INV_CONTEXT.ENFORCER_DENIED] = false
        --#endregion
    end
    if req_includes[INCLUDES.INV_CONTEXT] then
        interceptor_request_body[REQUEST.INV_CONTEXT] = inv_context
    end
    if resp_includes[INCLUDES.INV_CONTEXT] then
        shared_info[REQUEST.INV_CONTEXT] = inv_context
    end
end

local function handle_direct_respond(handle, interceptor_response_body, shared_info, request_id)
    if interceptor_response_body[RESPOSE.DIRECT_RESPOND] then
        handle:logDebug("Directly responding without calling the backend for request_id: " .. request_id)
        local headers = interceptor_response_body[RESPOSE.HEADERS_TO_ADD] or {}
        
        -- if interceptor_response_body.body is nil send empty, do not send client its payload back
        local body = interceptor_response_body.body or ""
        if body == "" then
            headers[STATUS] = headers[STATUS] or "204"
        else
            headers[STATUS] = headers[STATUS] or "200"
        end

        direct_respond(handle, headers, base64.decode(body), shared_info)
    end
end

---interceptor handler for request flow
---@param request_handle table - request_handle
---@param intercept_service {cluster_name: string, resource_path: string, timeout: number}
---@param req_includes {requestHeaders: boolean, requestBody: boolean, requestTrailer: boolean}
---@param resp_includes {requestHeaders: boolean, requestBody: boolean, requestTrailer: boolean, responseHeaders: boolean, responseBody: boolean, responseTrailers: boolean}
---@param inv_context table
function interceptor.handle_request_interceptor(request_handle, intercept_service, req_includes, resp_includes, inv_context)
    local shared_info = {}

    local request_headers = request_handle:headers()
    local request_id = request_headers:get("x-request-id")
    shared_info[SHARED.REQUEST_ID] = request_id

    local interceptor_request_body = {}
    -- including invocation context first it is required to read headers
    -- setting invocation context done only in the request flow and set it to the shared info to refer in response flow
    include_invocation_context(request_handle, req_includes, resp_includes, inv_context, interceptor_request_body, shared_info, request_headers)

    --#region read request headers
    local request_headers_table = {}
    if req_includes[INCLUDES.REQ_HEADERS] or resp_includes[INCLUDES.REQ_HEADERS] then
        for key, value in pairs(request_headers) do
            request_headers_table[key] = value
        end
    end
    if resp_includes[INCLUDES.REQ_HEADERS] then
        shared_info[REQUEST.REQ_HEADERS] = request_headers_table
    end
    --#endregion
    
    --#region read request body
    local request_body_base64
    if req_includes[INCLUDES.REQ_BODY] or resp_includes[INCLUDES.REQ_BODY] then
        local request_body = request_handle:body()
        local request_body_str
        if request_body then
            request_body_str = request_body:getBytes(0, request_body:length())
        else
            request_body_str = ""
        end
        request_body_base64 = base64.encode(request_body_str)
    end
    if resp_includes[INCLUDES.REQ_BODY] then
        shared_info[REQUEST.REQ_BODY] = request_body_base64
    end
    --#endregion

    --#region read request trailers
    local request_trailers_table = {}
    if req_includes[INCLUDES.REQ_TRAILERS] or resp_includes[INCLUDES.REQ_TRAILERS] then
        local request_trailers = request_handle:trailers()
        for key, value in pairs(request_trailers) do
            request_trailers_table[key] = value
        end
    end
    if resp_includes[INCLUDES.REQ_TRAILERS] then
        shared_info[REQUEST.REQ_TRAILERS] = request_trailers_table
    end
    --#endregion

    include_request_info(req_includes, interceptor_request_body, request_headers_table, request_body_base64, request_trailers_table)

    local interceptor_response_headers, interceptor_response_body_str = send_http_call(request_handle, interceptor_request_body, intercept_service)
    if check_interceptor_call_errors(request_handle, interceptor_response_headers, interceptor_response_body_str, shared_info, request_id, true) then
        return
    end

    local interceptor_response_body = json.decode(interceptor_response_body_str)

    handle_direct_respond(request_handle, interceptor_response_body, shared_info, request_id)
    modify_body(request_handle, interceptor_response_body, request_id)
    modify_headers(request_handle, interceptor_response_body)
    modify_trailers(request_handle, interceptor_response_body)

    if interceptor_response_body[RESPOSE.INTCPT_CONTEXT] then
        request_handle:logDebug("Updating interceptor context for the request_id: " .. request_id)
        shared_info[REQUEST.INTCPT_CONTEXT] = interceptor_response_body[RESPOSE.INTCPT_CONTEXT]
    end

    request_handle:streamInfo():dynamicMetadata():set("envoy.filters.http.lua", "shared.info", shared_info)
end

---interceptor handler for response flow
---@param response_handle table - response_handle
---@param intercept_service {cluster_name: string, resource_path: string, timeout: number}
---@param req_includes {requestHeaders: boolean, requestBody: boolean, requestTrailer: boolean}
---@param resp_includes {requestHeaders: boolean, requestBody: boolean, requestTrailer: boolean, responseHeaders: boolean, responseBody: boolean, responseTrailers: boolean}
function interceptor.handle_response_interceptor(response_handle, intercept_service, req_includes, resp_includes)
    local shared_info = response_handle:streamInfo():dynamicMetadata():get("envoy.filters.http.lua")["shared.info"]
    local request_id = shared_info[SHARED.REQUEST_ID] -- TODO: set this when request path is disabled also
    if shared_info[RESPOSE.DIRECT_RESPOND] then
        response_handle:logInfo("Ignoring response path intercept since direct responded for the request_id: " .. request_id)
        return
    end

    response_handle:logInfo("Continue request_id: " .. request_id)

    local interceptor_request_body = {}

    --#region read backend headers
    if resp_includes[INCLUDES.RESP_HEADERS] then
        local backend_headers = response_handle:headers()
        local backend_headers_table = {}
        for key, value in pairs(backend_headers) do
            backend_headers_table[key] = value
        end
        interceptor_request_body[REQUEST.RESP_HEADERS] = backend_headers_table
    end
    --#endregion

    --#region read backend body
    if resp_includes[INCLUDES.RESP_BODY] then
        local request_body = response_handle:body():getBytes(0, response_handle:body():length())
        interceptor_request_body[REQUEST.RESP_BODY] = base64.encode(request_body)
    end
    --#endregion

    --#region read backend trailers
    if resp_includes[INCLUDES.RESP_TRAILERS] then
        local backend_trailers = response_handle:trailers()
        local backend_trailers_table = {}
        for key, value in pairs(backend_trailers) do
            backend_trailers_table[key] = value
        end
        interceptor_request_body[REQUEST.RESP_TRAILERS] = backend_trailers_table
    end
    --#endregion

    include_request_info(req_includes, interceptor_request_body, shared_info[REQUEST.REQ_HEADERS], shared_info[REQUEST.REQ_BODY], shared_info[REQUEST.REQ_TRAILERS])
    interceptor_request_body[REQUEST.INTCPT_CONTEXT] = shared_info[REQUEST.INTCPT_CONTEXT]

    --#region invocation context
    if resp_includes[REQUEST.INV_CONTEXT] then
        interceptor_request_body[REQUEST.INV_CONTEXT] = shared_info[REQUEST.INV_CONTEXT]
    end
    --#endregion

    local interceptor_response_headers, interceptor_response_body_str = send_http_call(response_handle, interceptor_request_body, intercept_service)
    if check_interceptor_call_errors(response_handle, interceptor_response_headers, interceptor_response_body_str, shared_info, request_id, false) then
        return
    end
    local interceptor_response_body = json.decode(interceptor_response_body_str)

    modify_body(response_handle, interceptor_response_body, request_id)
    modify_headers(response_handle, interceptor_response_body)
    modify_trailers(response_handle, interceptor_response_body)
end

return interceptor
