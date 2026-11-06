(() => {
  "use strict";
  let ready;
  let initializedApp;
  let active = false;

  window.itoneWhatsAppPrepare = (appId, version) => {
    if (initializedApp && initializedApp !== appId) {
      return Promise.reject(new Error("La aplicación de Meta cambió. Recarga la página."));
    }
    if (ready) return ready;
    ready = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        ready = undefined;
        reject(new Error("Meta no respondió al cargar el SDK. Recarga y revisa bloqueadores."));
      }, 20000);
      const initialize = () => {
        clearTimeout(timeout);
        window.FB.init({ appId, version, cookie: true, xfbml: false });
        initializedApp = appId;
        resolve();
      };
      if (window.FB) {
        initialize();
        return;
      }
      window.fbAsyncInit = initialize;
      const script = document.createElement("script");
      script.src = "https://connect.facebook.net/es_LA/sdk.js";
      script.async = true;
      script.onerror = () => {
        clearTimeout(timeout);
        ready = undefined;
        script.remove();
        reject(new Error("No se pudo cargar el SDK de Meta."));
      };
      document.head.appendChild(script);
    });
    return ready;
  };

  // Called directly by the button, after preparation, to retain user activation
  // for the Facebook popup (no fetch or await before FB.login).
  window.itoneWhatsAppConnect = (configId) => {
    if (!initializedApp || !window.FB) {
      return Promise.reject(new Error("El SDK de Meta no está listo."));
    }
    if (active) return Promise.reject(new Error("Ya hay una conexión en curso."));
    active = true;
    return new Promise((resolve, reject) => {
      let code;
      let session;
      let settled = false;
      const cleanup = () => {
        active = false;
        settled = true;
        clearTimeout(timeout);
        window.removeEventListener("message", onMessage);
      };
      const fail = (message) => {
        if (settled) return;
        cleanup();
        reject(new Error(message));
      };
      const finish = () => {
        if (settled || !code || !session) return;
        cleanup();
        resolve(JSON.stringify({
          code,
          event: session.event,
          waba_id: session.data.waba_id,
          phone_number_id: session.data.phone_number_id,
        }));
      };
      const onMessage = (event) => {
        if (!["https://www.facebook.com", "https://web.facebook.com"].includes(event.origin)) return;
        let data;
        if (typeof event.data === "string") {
          try {
            data = JSON.parse(event.data);
          } catch {
            return; // Other Facebook SDK messages are not signup payloads.
          }
        } else {
          data = event.data;
        }
        if (!data || data.type !== "WA_EMBEDDED_SIGNUP") return;
        if (data.event === "CANCEL") {
          fail("Conexión cancelada en Meta. No se guardó ninguna configuración.");
        } else if (data.event === "ERROR") {
          fail("Meta reportó un error durante la conexión. Revisa tu configuración de Embedded Signup.");
        } else if (data.event === "FINISH_WHATSAPP_BUSINESS_APP_ONBOARDING") {
          if (!/^\d+$/.test(data.data?.waba_id || "")) {
            fail("Meta no devolvió el identificador de la cuenta.");
            return;
          }
          session = data;
          finish();
        } else if (typeof data.event === "string" && data.event.startsWith("FINISH")) {
          fail("Seleccionaste Cloud API sin coexistencia. Conecta tu cuenta existente de WhatsApp Business.");
        }
      };
      const timeout = setTimeout(() => fail("La conexión expiró. Vuelve a intentarlo."), 10 * 60 * 1000);
      window.addEventListener("message", onMessage);
      try {
        window.FB.login((response) => {
          if (settled) return;
          if (!response.authResponse?.code) {
            fail("Meta no autorizó la conexión o se cerró la ventana.");
            return;
          }
          code = response.authResponse.code;
          finish();
        }, {
          config_id: configId,
          response_type: "code",
          override_default_response_type: true,
          extras: {
            setup: {},
            featureType: "whatsapp_business_app_onboarding",
            sessionInfoVersion: "3",
          },
        });
      } catch (error) {
        fail(error.message || "No se pudo abrir la conexión de Meta.");
      }
    });
  };
})();
