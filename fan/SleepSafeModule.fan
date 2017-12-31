using afIoc
using afIocConfig
using afBedSheet
using afConcurrent::ActorPools
using concurrent::ActorPool

@NoDoc
const class SleepSafeModule {
	
	Void defineServices(RegistryBuilder bob) {
		bob.addService(CsrfCrypto#)
		bob.addService(SleepSafeMiddleware#)
		bob.addService(CsrfTokenGeneration#)
		bob.addService(CsrfTokenValidation#)
	}

	Void onRegistryStartup(Configuration config) {
		scope := config.scope
		config["afSleepSafe.csrfKeyGen"] = |->| {
			crypto := (CsrfCrypto) scope.serviceById(CsrfCrypto#.qname)
			crypto.generateKey
		}
		config["afSleepSafe.logGuards"] = |->| {
			middleware := (SleepSafeMiddleware) scope.serviceById(SleepSafeMiddleware#.qname)
			msg := "SleepSafe knowing your application is protected against: "
			msg += middleware.guards.rw.sort.join(", ") { it.protectsAgainst }
			typeof.pod.log.info(msg)
		}
	}

	@Contribute { serviceType=SleepSafeMiddleware# }
	Void contributeSleepSafeMiddleware(Configuration config) {
		// request checkers
		config[SameOriginGuard#]	= config.build(SameOriginGuard#)
		config[SessionHijackGuard#]	= config.build(SessionHijackGuard#)
		config[CsrfTokenGuard#]		= config.build(CsrfTokenGuard#)
		
		// header setters
		config[CspGuard#]			= config.build(CspGuard#)
		config[ContentTypeGuard#]	= config.build(ContentTypeGuard#)
		config[FrameOptionsGuard#]	= config.build(FrameOptionsGuard#)
		config[ReferrerPolicyGuard#]= config.build(ReferrerPolicyGuard#)
		config[XssProtectionGuard#]	= config.build(XssProtectionGuard#)
	}

	@Contribute { serviceType=CsrfTokenGeneration# }
	Void contributeCsrfTokenGeneration(Configuration config, ConfigSource configSrc, HttpSession httpSession) {
		config["timestamp"] = |Str:Obj? hash| {
			hash["ts"] = Base64.toB64(DateTime.nowTicks / 1ms.ticks)
		}
		config["sessionId"] = |Str:Obj? hash| {
			if (httpSession.exists)
				hash["sId"] = httpSession.id
		}
	}

	@Contribute { serviceType=CsrfTokenValidation# }
	Void contributeCsrfTokenValidation(Configuration config, ConfigSource configSrc, HttpSession httpSession) {
		config["timestamp"] = |Str:Obj? hash| {
			timeout 	:= (Duration)  configSrc.get("afSleepSafe.csrfTokenTimeout", Duration#)
			timestamp	:= Base64.fromB64(hash.get("ts", "0")) * 1ms.ticks
			duration	:= Duration(DateTime.nowTicks - timestamp)
			if (duration >= timeout)
				throw Err("Token exceeds ${timeout} timeout: ${duration}")
		}
		config["sessionId"] = |Str:Obj? hash| {
			if (hash.containsKey("sId")) {
				if (!httpSession.exists)
					// no session means a stale link
					// we could throw an CSRF err, but more likely the app will want to redirect to a login page 
					return
				if (httpSession.id != hash["sId"])
					throw Err("Session ID mismatch")
			}
			// if no sId but HTTP session exists...
			// that's normal 'cos the session is normally created *after* the token is generated
			// don't force the user to re-gen the csrf token - we're supposed to be invisible (almost!)
		}
	}

	@Contribute { serviceType=Routes# }
	Void contributeRoutes(Configuration config, ConfigSource configSrc, HttpRequest httpReq) {
		reportUri := (Uri?             ) configSrc.get("afSleepSafe.csp.report-uri", Uri#, false)
		reportFn  := (|Str:Obj?->Obj?|?) configSrc.get("afSleepSafe.cspReportFn", null, false)
		if (reportUri != null && reportFn != null) {
			routeFn	:=  |->Obj?| {
				json := httpReq.body.jsonMap
				return reportFn(json) ?: Text.fromPlain("OK")
			}.toImmutable
			
			config.add(Route(reportUri,	routeFn, "POST"))
		}
	}
	
	@Contribute { serviceType=MiddlewarePipeline# }
	Void contributeMiddleware(Configuration config, SleepSafeMiddleware middleware) {
		config.set("SleepSafeMiddleware", middleware).before("afBedSheet.routes")
	}

	@Contribute { serviceType=FactoryDefaults# }
	Void contributeFactoryDefaults(Configuration config) {
		config["afSleepSafe.rejectedStatusCode"]	= "403"
		
		config["afSleepSafe.csrfTokenName"]			= "_csrfToken"
		config["afSleepSafe.csrfTokenTimeout"]		= "60min"
		config["afSleepSafe.frameOptions"]			= "SAMEORIGIN"
		config["afSleepSafe.referrerPolicy"]		= "no-referrer, strict-origin-when-cross-origin"
		config["afSleepSafe.sameOriginWhitelist"]	= ""
		config["afSleepSafe.sessionHijackEncrypt"]	= true
		config["afSleepSafe.sessionHijackHeaders"]	= "User-Agent, Accept-Language"
		config["afSleepSafe.xssProtectionEnable"]	= true
		config["afSleepSafe.xssProtectionMode"]		= "block"

		config["afSleepSafe.csp.default-src"]		= "'self'"
		config["afSleepSafe.csp.object-src"]		= "'none'"
		config["afSleepSafe.csp.base-uri"]			= "'self'"
		config["afSleepSafe.csp.form-action"]		= "'self'"
		config["afSleepSafe.csp.frame-ancestors"]	= "'self'"
		config["afSleepSafe.csp.report-uri"]		= "/_sleepSafeCspViolation"
		config["afSleepSafe.cspReportOnly"]			= false
		config["afSleepSafe.cspReportFn"]			= |Str:Obj? report| {
			txt := JsonWriter(true).writeJson(report)
			typeof.pod.log.warn("Content-Security-Policy Violation:\n${txt}")
		}
	}

	@Contribute { serviceType=ActorPools# }
	Void contributeActorPools(Configuration config) {
		config["csrfKeyGen"] = ActorPool() { it.name = "CSRF Key Gen" }
	}
}
