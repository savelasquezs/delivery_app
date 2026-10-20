# Permisos laborales en Delivery App

La entrada **Mis permisos** está en el encabezado de Inicio, con contador de novedades. Muestra solo solicitudes propias; un administrador que inició sesión como domiciliario tampoco decide permisos ajenos desde esta app. Crear/modificar, cancelar, adjuntar/eliminar soportes y registrar regreso exigen contraseña actual. La confirmación usa el JWT existente: nunca invoca login, nunca guarda la contraseña ni modifica la jornada/ruta.

Las fechas del formulario se interpretan en Colombia (UTC−05), independientemente de la zona del teléfono. Los conflictos HTTP 409 obligan a consultar la versión actual. La creación conserva RequestKey durante un reintento; los soportes conservan UploadKey y bytes en memoria para reintentos, incluidos los posteriores al refresh de JWT. No hay cola offline para contraseñas ni documentos. Al abandonar el detalle se descarta el archivo seleccionado.

PDF/JPG/PNG: cinco soportes por solicitud, máximo 5 MiB cada uno, firma y tamaño validados también por la API. El selector nativo copia temporalmente el archivo y se solicita su limpieza después de leerlo. Descargar requiere autorización y una selección explícita de destino para guardar una copia; esa copia queda bajo control del usuario. No se crean URLs públicas ni se escriben motivos/soportes en preferencias locales.

FCM usa `employee_leave_changed` y solo UUID de solicitud, id del destinatario y versión. El enlace pendiente en memoria solo se abre después de autenticar al destinatario. Las notificaciones de seguimiento y cierre de jornada conservan sus contratos. La bandeja/detalle y el contador se reconcilian al regresar al primer plano; una notificación perdida no es la fuente de verdad.

Durante el almuerzo se permiten `/permisos` y sus detalles/formularios, sin habilitar operaciones de reparto. Regresar a Inicio vuelve a mostrar el control de almuerzo hasta confirmar el regreso.

## Publicación coordinada

Requiere SenorArroz PR #48 y senorArrozFront PR #29. Antes de publicar: ejecutar la migración aditiva y clasificación explícita de cuentas de cocina, configurar el bucket privado y el enlace web del backend, desplegar API, validar con cuentas de prueba y luego publicar clientes. Se conserva versionName `1.2.5`; el flujo existente calcula versionCode. Este PR no publica en Google Play ni cambia límites de versión del servidor.

Validación automatizada: pruebas de contrato HTTP, privacidad de contraseñas, reintento multipart, formatos/tamaño, zona horaria, navegación/notificaciones y diálogo de confirmación; suite existente de sesión/GPS y compilación Android. La entrega real de FCM, correo y selector/exportación en teléfonos de producción requiere smoke posterior al despliegue autorizado.
