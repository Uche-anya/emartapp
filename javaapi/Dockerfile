FROM openjdk:8 AS build_image

WORKDIR /usr/src/app/

RUN apt update && apt install maven -y

COPY ./ /usr/src/app/

RUN mvn install -DskipTests

FROM openjdk:8

WORKDIR /usr/src/app/

COPY --from=build_image /usr/src/app/target/book-work-0.0.1-SNAPSHOT.jar ./book-work-0.0.1.jar

EXPOSE 9000

ENTRYPOINT ["java", "-jar", "book-work-0.0.1.jar"]