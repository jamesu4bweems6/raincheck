import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    kotlin("jvm")
    kotlin("plugin.serialization")
    application
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

application {
    mainClass.set("cn.raincheck.cli.MainKt")
}

// 协议描述文件由 protocol/profile.json 单一来源同步，避免三端配置漂移
val syncProtocol by tasks.registering(Copy::class) {
    from(rootProject.layout.projectDirectory.file("protocol/profile.json"))
    into(layout.buildDirectory.dir("generated/protocol"))
}

val syncVectors by tasks.registering(Copy::class) {
    from(rootProject.layout.projectDirectory.dir("protocol/vectors"))
    into(layout.buildDirectory.dir("generated/protocol/vectors"))
}

sourceSets {
    main {
        resources.srcDir(layout.buildDirectory.dir("generated/protocol"))
    }
}

tasks.named("processResources") {
    dependsOn(syncProtocol, syncVectors)
}

tasks.named<CreateStartScripts>("startScripts") {
    defaultJvmOpts = listOf("-Dfile.encoding=UTF-8", "-Dstdout.encoding=UTF-8")
}

dependencies {
    implementation(project(":core"))
    runtimeOnly("org.slf4j:slf4j-nop:2.0.16")
    testImplementation(kotlin("test"))
}
