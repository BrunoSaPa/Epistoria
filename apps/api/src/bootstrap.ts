import { ValidationPipe, type INestApplication } from '@nestjs/common';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import helmet from 'helmet';
import { json } from 'express';
import { randomUUID } from 'node:crypto';
import { AppModule } from './app.module.js';

export async function configureApplication(app: INestApplication): Promise<void> {
  app.use(helmet());
  app.use(json({ limit: '10mb', type: 'application/json' }));
  app.use((request: { headers: Record<string, unknown> }, response: { setHeader: (name: string, value: string) => void }, next: () => void) => {
    const requestId = typeof request.headers['x-request-id'] === 'string'
      ? request.headers['x-request-id']
      : randomUUID();
    response.setHeader('x-request-id', requestId);
    next();
  });
  app.setGlobalPrefix('v1');
  app.useGlobalPipes(
    new ValidationPipe({
      transform: true,
      whitelist: true,
      forbidNonWhitelisted: true,
      stopAtFirstError: false,
    }),
  );
  app.enableShutdownHooks();

  const document = SwaggerModule.createDocument(
    app,
    new DocumentBuilder()
      .setTitle('Epistoria Sync API')
      .setDescription('Opaque, end-to-end encrypted synchronization and trusted processing queue')
      .setVersion('0.1.0')
      .addBearerAuth()
      .build(),
    { operationIdFactory: (_controller, method) => method },
  );
  SwaggerModule.setup('docs', app, document, {
    jsonDocumentUrl: 'openapi.json',
    swaggerOptions: { persistAuthorization: false },
  });
}

export { AppModule };

