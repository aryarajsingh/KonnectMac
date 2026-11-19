# Notificaciones y portapapeles

En Apfelbindung, abre **Settings → Plugins** y busca el dispositivo emparejado. Las preferencias se guardan por dispositivo.

## Notificaciones

- En **Notifications → Notification apps…** puedes elegir qué apps del teléfono aparecen en este Mac. La lista se llena a medida que llegan notificaciones. Desactivar una app también oculta las notificaciones que ya mostró en el Mac, sin borrarlas en el teléfono.
- Para impedir que una app envíe sus notificaciones, elige las apps permitidas en la configuración del complemento de notificaciones de **KDE Connect en Android**. El filtro del Mac solo controla lo que Apfelbindung muestra después de recibirlo; no controla los avisos del complemento independiente de llamadas.
- Si Android incluye acciones en una notificación, puedes ejecutarlas desde **Phone actions** en la lista de Apfelbindung.
- macOS no ofrece una API pública para reenviar las notificaciones de otras apps del Mac a Android. Apfelbindung no admite esa dirección.

## Portapapeles de texto

En **Clipboard Sync** puedes activar por separado **Send Mac clipboard automatically** y **Receive phone clipboard**. **Send clipboard now** envía el texto actual del Mac una vez, aunque el envío automático esté desactivado.

Desde Android 10, Android normalmente impide que KDE Connect lea el portapapeles en segundo plano. Apfelbindung puede aplicar automáticamente el texto que recibe, pero no puede hacer que el teléfono lo envíe. Si copiar en otra app no envía el texto, abre KDE Connect en el teléfono, selecciona el Mac y usa **Enviar portapapeles**.

## Verificación en macOS y Android

| Prueba | Resultado esperado |
| --- | --- |
| Envía dos notificaciones de la misma app con imágenes distintas, o actualiza una notificación sin cambiar su texto. | Cada una muestra su imagen; una actualización que no trae imagen ni hash no conserva la anterior. |
| Actualiza o cancela una notificación mientras descarga su imagen. | La descarga anterior no reemplaza la actualización ni restaura la notificación cancelada. |
| Bloquea una app, envía otra notificación de esa app y reinicia Apfelbindung. | No aparece en el Mac y el filtro se conserva; las demás apps y dispositivos no cambian. |
| Ejecuta una acción de Android desde **Phone actions** o responde desde un aviso compatible de macOS. | KDE Connect ejecuta la acción o entrega la respuesta para esa notificación. |
| Envía `A` desde Android, copia `B` en el Mac y vuelve a enviar `A` desde Android. | El Mac vuelve a pegar `A`; recibir texto no lo reenvía a Android ni a otro dispositivo conectado. |
| Desactiva **Receive phone clipboard** y envía otro texto desde Android. | El portapapeles del Mac no cambia. |
| Copia texto nuevo en el Mac con el teléfono desconectado y vuelve a conectarlo. | Una sincronización de conexión con una marca de tiempo anterior no reemplaza ese texto. |
