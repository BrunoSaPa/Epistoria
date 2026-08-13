import 'reflect-metadata';
import { Logger } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { AppModule, configureApplication } from './bootstrap.js';
import { environment } from './config/environment.js';

async function main(): Promise<void> {
  const config = environment();
  const app = await NestFactory.create(AppModule, {
    bodyParser: false,
    logger: config.nodeEnv === 'production' ? ['log', 'warn', 'error'] : ['log', 'warn', 'error', 'debug'],
  });
  await configureApplication(app);
  await app.listen(config.port, '0.0.0.0');
  Logger.log(`Listening on port ${config.port}`, 'Bootstrap');
}

void main();

