/*
 * Copyright (c) 2018, WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
 *
 * WSO2 Inc. licenses this file to you under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */
package org.wso2.micro.gateway.tests.services;

import io.netty.handler.codec.http.HttpHeaderNames;
import org.testng.Assert;
import org.testng.annotations.AfterClass;
import org.testng.annotations.BeforeClass;
import org.testng.annotations.Test;
import org.wso2.micro.gateway.tests.common.BaseTestCase;
import org.wso2.micro.gateway.tests.common.KeyValidationInfo;
import org.wso2.micro.gateway.tests.common.MockAPIPublisher;
import org.wso2.micro.gateway.tests.common.MockHttpServer;
import org.wso2.micro.gateway.tests.common.model.API;
import org.wso2.micro.gateway.tests.common.model.ApplicationDTO;
import org.wso2.micro.gateway.tests.util.HttpClientRequest;
import org.wso2.micro.gateway.tests.util.TestConstant;

import java.util.HashMap;
import java.util.Map;

public class APIInvokeTestCase extends BaseTestCase {
    private String prodToken, sandToken, jwtTokenProd, jwtTokenSand;

    @BeforeClass
    public void start() throws Exception {
        String label = "apimTestLabel";
        String project = "apimTestProject";
        //get mock APIM Instance
        MockAPIPublisher pub = MockAPIPublisher.getInstance();
        API api = new API();
        api.setName("PizzaShackAPI");
        api.setContext("/pizzashack");
        api.setProdEndpoint("http://localhost:9443/echo/prod");
        api.setSandEndpoint("http://localhost:9443/echo/sand");
        api.setVersion("1.0.0");
        api.setProvider("admin");
        //Register API with label
        pub.addApi(label, api);

        //Define application info
        ApplicationDTO application = new ApplicationDTO();
        application.setName("jwtApp");
        application.setTier("Unlimited");
        application.setId((int) (Math.random() * 1000));

        //Register a production token with key validation info
        KeyValidationInfo info = new KeyValidationInfo();
        info.setApiName(api.getName());
        info.setApiPublisher(api.getProvider());
        info.setAuthorized(true);
        info.setKeyType(TestConstant.KEY_TYPE_PRODUCTION);

        //Register a production token with key validation info
        prodToken = pub.getAndRegisterAccessToken(info);

        //Register a sandbox token with key validation info
        KeyValidationInfo infoSand = new KeyValidationInfo();
        infoSand.setApiName(api.getName());
        infoSand.setApiPublisher(api.getProvider());
        infoSand.setAuthorized(true);
        infoSand.setKeyType(TestConstant.KEY_TYPE_SANDBOX);
        sandToken = pub.getAndRegisterAccessToken(infoSand);

        jwtTokenProd = getJWT(api, application, "Unlimited", TestConstant.KEY_TYPE_PRODUCTION);
        jwtTokenSand = getJWT(api, application, "Unlimited", TestConstant.KEY_TYPE_SANDBOX);
        //generate apis with CLI and start the micro gateway server
        super.init(label, project);
    }

    @Test(description = "Test API invocation with a oauth token")
    public void testApiInvoke() throws Exception {
        //test prod endpoint
        invoke(prodToken, MockHttpServer.PROD_ENDPOINT_RESPONSE);

        //test sand endpoint
        invoke(sandToken, MockHttpServer.SAND_ENDPOINT_RESPONSE);
    }

    @Test(description = "Test API invocation with a JWT token")
    public void testApiInvokeWithJWT() throws Exception {
        //test prod endpoint with jwt token
        invoke(jwtTokenProd, MockHttpServer.PROD_ENDPOINT_RESPONSE);

        //test sand endpoint
        invoke(jwtTokenSand, MockHttpServer.SAND_ENDPOINT_RESPONSE);
    }

    private void invoke(String token, String responseData) throws Exception {
        Map<String, String> headers = new HashMap<>();
        //test endpoint with token
        headers.put(HttpHeaderNames.AUTHORIZATION.toString(), "Bearer " + token);
        org.wso2.micro.gateway.tests.util.HttpResponse response = HttpClientRequest
                .doGet(microGWServer.getServiceURLHttp("pizzashack/1.0.0/menu"), headers);
        Assert.assertNotNull(response);
        Assert.assertEquals(response.getData(), responseData);
        Assert.assertEquals(response.getResponseCode(), 200, "Response code mismatched");
    }

    @AfterClass
    public void stop() throws Exception {
        //Stop all the mock servers
        super.finalize();
    }
}
